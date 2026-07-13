# ISSUES.md

File format: <https://github.com/schwa/issues-format>

---

## 1: Add live transport tests with a mock URLProtocol

+++
status: closed
priority: medium
kind: task
labels: testing, effort:m
created: 2026-06-23T23:13:55Z
updated: 2026-07-13T15:22:22Z
closed: 2026-07-13T15:22:22Z
+++

All provider tests are parser-level (StreamAccumulator / OpenAIStreamAccumulator). Nothing exercises AnthropicProvider/OpenAIProvider end-to-end over a real URLSession. Add a MockURLProtocol that feeds canned SSE byte streams through the actual providers to verify: request construction (auth headers, anthropic-beta/user-agent for OAuth, x-api-key vs Bearer), HTTP status handling (non-2xx -> httpError with body), and partial-line SSE buffering. Largest gap: the networking layer is unproven by tests, only manually verified against LM Studio and Anthropic.

- `2026-07-13T15:22:22Z`: Added ProviderTransportTests exercising AnthropicProvider (api-key + OAuth headers, non-2xx → AnthropicError.httpError, models GET) and OpenAIProvider (Bearer + JSON headers, non-2xx → OpenAIError.httpError, models GET) end-to-end through StreamingTransport with a URLProtocol stub.

---

## 2: Harden SSE parsing against awkward chunk boundaries

+++
status: closed
priority: medium
kind: bug
labels: bug, testing, effort:s
created: 2026-06-23T23:14:06Z
updated: 2026-07-13T02:21:32Z
closed: 2026-07-13T02:21:32Z
+++

Both providers parse the SSE stream via bytes.lines, which assumes each 'data:' payload is a single newline-delimited line. Real SSE can split a JSON payload across reads, use CRLF, or include multi-line data fields. Verify/handle: CRLF line endings, a JSON payload that spans chunk boundaries, and blank-line event separators. Add tests that drive the provider with deliberately split chunks.

- `2026-07-13T02:21:32Z`: Verified via 4 regression tests in StreamingTransportTests: CRLF line endings, bare CR terminators, blank-line event separators, and a JSON payload split across three network chunks. All pass against the existing bytes.lines-based parser; URLSession's async byte stream handles line reassembly transparently. Added a small ChunkedURLProtocol that delivers a base64-encoded pipe-separated list of chunks so the payload-split case exercises actual didLoad boundaries.

---

## 3: Add bounded retry with backoff for transient API failures

+++
status: closed
priority: medium
kind: enhancement
labels: enhancement, effort:m
created: 2026-06-23T23:14:06Z
updated: 2026-07-13T02:27:16Z
closed: 2026-07-13T02:27:16Z
+++

No retry anywhere. A transient 429 or 5xx (e.g. Anthropic 529 overloaded) kills the whole turn. pi's reference OAuth code retried token exchange on 429/5xx with backoff and honored Retry-After / x-should-retry. Add bounded retry (a few attempts, exponential backoff, respect Retry-After) to: the Anthropic OAuth token exchange/refresh, and the streaming message call for both providers. Must not retry non-idempotent partial streams blindly — only retry before the first byte is yielded.

- `2026-07-13T02:27:16Z`: Landed. New Sources/CollaborationKit/Core/Retry.swift with:

- RetryPolicy (maxAttempts / baseDelay / maxDelay) with a sensible default (3 attempts, 0.5s→1s→2s capped at 8s) and .none for opt-out.
- RetryReason classifier for standard transient statuses (408, 425, 429, 500, 502, 503, 504, 529) and URLError transport failures.
- parseRetryAfter for both delta-seconds and HTTP-date Retry-After headers.

Wired into:
- AnthropicOAuth.exchange — retries 429/5xx and transport failures with backoff, honoring Retry-After (whichever is larger of computed backoff or server-supplied delay).
- StreamingTransport.stream — retries only the initial HTTP round-trip (before any bytes yield to the consumer), so mid-turn partial streams are never re-issued. Drains body between retries for connection reuse.

Added 7 unit tests (RetryTests) for policy/classifier/header parsing and 3 serialized integration tests (TransportRetryTests) exercising the transport retry loop with a sequenced URLProtocol.

---

## 4: Honor task cancellation cleanly in LLMSession and providers

+++
status: closed
priority: high
kind: enhancement
labels: enhancement, effort:m
created: 2026-06-23T23:14:06Z
updated: 2026-07-13T16:28:28Z
closed: 2026-07-13T16:28:28Z
+++

send() is not easily cancellable mid-turn and the session events stream never finishes (its continuation is never terminated). For any UI, cancelling a turn should stop the in-flight request, stop the tool loop, and let observers know. Wire Task cancellation through the provider streams and the session loop; consider finishing or yielding a terminal event so the events AsyncStream completes.

- `2026-07-13T02:43:06Z`: Attempted: added SessionEvent.turnCancelled + Task.checkCancellation() at strategic points in runLoop + close() to finish the events stream. Cancellation didn't propagate from the caller's Task into the actor's method body — Task.checkCancellation() never fired inside runLoop even after outer task.cancel(). Punting: real fix likely needs withTaskCancellationHandler + a nonisolated cancellation flag the actor polls, and warrants a careful test plan for the actor/AsyncThrowingStream cancellation interaction. Not autonomous-friendly — needs a design pass on how cancellation should reach the actor.
- `2026-07-13T14:19:43Z`: Autonomous run 2: re-encountered. Prior punt reason still applies — actor/AsyncThrowingStream cancellation needs a design pass, not another attempt. Skipping again this run.

---

## 5: Preserve partial work when maxIterations is exceeded

+++
status: closed
priority: medium
kind: enhancement
labels: enhancement, effort:s
created: 2026-06-23T23:14:14Z
updated: 2026-07-13T14:57:36Z
closed: 2026-07-13T14:57:36Z
+++

SessionError.maxIterationsExceeded throws out of send() and discards the partial turn (accumulated text, tool calls/results so far are lost to the caller, though history is mutated). Consider returning what happened instead of throwing it away — e.g. include the partial assistant text in the error, or return a result type that distinguishes 'completed' vs 'hit iteration cap'.

---

## 6: Add a turn-complete summary event with total usage and stop reason

+++
status: closed
priority: medium
kind: enhancement
labels: enhancement, effort:s
created: 2026-06-23T23:14:14Z
updated: 2026-07-13T14:59:50Z
closed: 2026-07-13T14:59:50Z
+++

Usage is emitted per model response (SessionEvent.usage), but there is no single turn-level summary: total tokens for the turn plus the stop reason. turnComplete currently carries only the final text. Consider enriching turnComplete (or adding a new event) with aggregated TokenUsage for the turn and the provider stop reason, so callers don't have to sum usage events themselves.

---

## 7: Conversation history compaction with user-defined strategy

+++
status: closed
priority: medium
kind: feature
labels: effort:l
created: 2026-06-24T01:06:10Z
updated: 2026-07-13T15:09:45Z
closed: 2026-07-13T15:09:45Z
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
status: closed
priority: low
kind: task
labels: effort:m
created: 2026-06-24T01:10:57Z
updated: 2026-07-13T04:53:05Z
closed: 2026-07-13T04:53:05Z
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
status: closed
priority: high
kind: task
labels: effort:m
created: 2026-06-24T01:10:58Z
updated: 2026-07-13T06:45:02Z
closed: 2026-07-13T06:45:02Z
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
status: closed
priority: medium
kind: feature
labels: effort:xl
created: 2026-07-13T00:40:29Z
updated: 2026-07-13T05:53:21Z
closed: 2026-07-13T05:53:21Z
+++

See rfcs/0003-model-object-tool-macro.md.

- `2026-07-13T01:01:38Z`: Slice 1 landed: core `@CollaborationTools` / `@CollaborationTool` macros, primitives + Optional/Array/[String:T], throws/async/actor call-site handling, `CollaborationResultConvertible`. Framework bridges (FoundationModels/SwiftData/AppIntents), `@CollaborationField`, `@CollaborationSchema`, nested-object handling, doc-comment mining, and name prefixing are deferred to later slices.
- `2026-07-13T05:53:21Z`: Slice 1 shipped (@CollaborationTools / @CollaborationTool, primitives + Optional/Array/[String:T], throws/async/actor + @MainActor call-site handling, CollaborationResultConvertible, CollaborationSchemaConvertible, prefix:, name:, requiresApproval:, and doc-comment mining via #19). Remaining RFC 0003 work — FoundationModels (#16), SwiftData (#17), and AppIntents (#18) bridges — tracked as trailing issues in their own right; no umbrella needed.

---

## 15: Consolidate credential storage across targets

+++
status: closed
priority: high
kind: task
labels: effort:m
created: 2026-07-13T00:55:41Z
updated: 2026-07-13T03:10:40Z
closed: 2026-07-13T03:10:40Z
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

- `2026-07-13T02:10:52Z`: Punt from autonomous run: this is a design decision, not an implementation task. Issue itself lists three viable directions (common protocol; deprecate file store; formalize split) with different trade-offs for CLI vs UI vs host use cases. Autonomous run isn't comfortable picking a direction unilaterally — needs a product call on which option to pursue. In the meantime the two stores co-exist fine and every credential UI path today goes through the Keychain one.
- `2026-07-13T03:10:40Z`: Landed. Core no longer ships credential persistence:

- Deleted Sources/CollaborationKit/Credentials.swift (file-based CredentialStore).
- Deleted Sources/CollaborationKit/Anthropic/OAuthTokenProvider.swift (the actor that persisted refreshes to disk).
- Added Sources/collab-cli/CLICredentialStore.swift — UserDefaults-backed store used only by the CLI. Same shape (apiKey / oauth / self-refreshing token-provider closure) as KeychainCredentialStore, appropriate for a CLI executable.
- Updated collab-cli's Login/Chat to use it. No more ~/.config/collaborationkit/credentials.json.
- Dropped the file-store test in OAuthTests; the old CredentialStoreTests file went with the type.
- README rewritten: Core stays storage-agnostic, apps use KeychainCredentialStore, CLI uses CLICredentialStore.

CLI vs UI never see each other's credentials — expected; different security models. Two tests dropped, 102 remaining pass.

---

## 16: RFC 0003: FoundationModels bridge for @Generable types and cross-backend tool reuse

+++
status: open
priority: medium
kind: feature
labels: effort:l, deferred
depends: 14, 15
created: 2026-07-13T01:02:34Z
updated: 2026-07-13T14:53:02Z
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
labels: effort:l, deferred
depends: 14, 15
created: 2026-07-13T01:02:41Z
updated: 2026-07-13T15:13:26Z
+++

Slice 1 does not know about SwiftData @Model types. Annotating a @Model with @CollaborationTools does nothing useful — the user still has to hand-write list/fetch/create/update/delete tools.

Missing per RFC 0003 §3.2:

- `2026-07-13T01:02:41Z`: Derived CRUD tools (list, fetch(id:), create, update(id:, ...), delete(id:)) for a @Model type.
- `2026-07-13T01:02:41Z`: @CollaborationField(.readOnly | .hidden | .writable) per property to control the derived surface.
- `2026-07-13T01:02:41Z`: Predicate parameter → declarative filter schema (not full Predicate DSL).
- `2026-07-13T01:02:41Z`: A collaborationTools(in: ModelContext) accessor variant, since these tools need a ModelContext.
- `2026-07-13T01:02:41Z`: Hand-written @CollaborationTool methods on the same @Model override the derived tool of the same name.
- `2026-07-13T01:02:41Z`: OS-version gating in the bridge module.
- `2026-07-13T17:06:27Z`: Drafted as [RFC 0004](rfcs/0004-swiftdata-bridge.md) — standalone spec expanding RFC 0003 §3.2. Proposes 4 slices (A: read-only, B: filter/sort, C: mutations, D: relationships). Open questions still to resolve: id inference vs. explicit `.id`, concurrency gating, implicit `save()`, default `requiresApproval` for mutations.

---

## 18: RFC 0003: AppIntents bridge exposes AppIntent.perform() as a tool

+++
status: open
priority: medium
kind: feature
labels: effort:l, deferred
depends: 14, 15
created: 2026-07-13T01:02:46Z
updated: 2026-07-13T14:53:02Z
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
status: closed
priority: low
kind: enhancement
labels: effort:s
depends: 14
created: 2026-07-13T01:02:51Z
updated: 2026-07-13T05:50:10Z
closed: 2026-07-13T05:50:10Z
+++

Every @CollaborationTool method has to repeat its description in the attribute argument, even when the method already has a /// doc comment saying the same thing.

Missing per RFC 0003 open question 2:

- `2026-07-13T01:02:51Z`: If the attribute has no description argument, use the member's /// doc comment as the tool description.
- `2026-07-13T01:02:51Z`: Explicit attribute string always wins.
- `2026-07-13T01:02:51Z`: Requires enabling doc-comment trivia access in the macro.
- `2026-07-13T05:50:10Z`: Slice 2: description-less @CollaborationTool falls back to the method's /// doc-comment summary (stops at first blank line or DocC keyword). Explicit attribute string still wins. Missing description now diagnoses. Demo, README, and tests updated.

---

## 20: RFC 0003: tool-name prefixing and collision handling across multiple annotated types

+++
status: closed
priority: medium
kind: enhancement
labels: effort:s
depends: 14
created: 2026-07-13T01:02:56Z
updated: 2026-07-13T02:22:54Z
closed: 2026-07-13T02:22:54Z
+++

Slice 1 uses the bare Swift member name as the tool name. When two @CollaborationTools types both expose e.g. 'create', the model sees two tools with the same name and one wins silently.

Missing per RFC 0003 open question 5:
- Default naming prefixes the tool name with the owning type name (or a shortened form of it).
- Per-attribute override to force a specific tool name.
- Documented guidance for hosts that merge tools from multiple stores.

- `2026-07-13T02:22:54Z`: Landed. Two knobs, both opt-in and non-breaking:

- `@CollaborationTools(prefix: "Notes")` — every derived tool becomes `Notes_<method>`.
- `@CollaborationTool("desc", name: "custom.name")` — per-tool override wins over both the prefix and the bare method name.

Bare method name remains the default when neither is used, so existing call sites keep working. Added CollaborationToolsPrefixTests exercising the three combinations.

---

## 21: RFC 0003: nested @CollaborationTools objects as parameters (ID reference vs value)

+++
status: closed
priority: high
kind: feature
labels: effort:m
depends: 14, 15
created: 2026-07-13T01:03:03Z
updated: 2026-07-13T02:05:13Z
closed: 2026-07-13T02:05:13Z
+++

There is no defined behaviour when a @CollaborationTool method takes a value of another @CollaborationTools-annotated type as a parameter, or returns one. Right now such a parameter fails schema derivation.

Missing per RFC 0003 open question 3:

- `2026-07-13T01:03:03Z`: Decide and document: nested types are passed by ID, not by inlined value.
- `2026-07-13T01:03:03Z`: Macro emits a schema referencing the ID type; the tool body dereferences on entry.
- `2026-07-13T01:03:03Z`: What 'ID type' means for a given store is user-declared, likely via a small protocol.
- `2026-07-13T01:03:03Z`: Test that the model sees a stable ID schema and not the full nested object.
- `2026-07-13T02:05:13Z`: Documented in RFC 0003 (Nested-object rule) and the @CollaborationTools doc comment. Split by identity: referent objects (host-owned, identity-bearing) pass ids; value objects (transient, no identity) inline via CollaborationSchemaConvertible (#25). No macro-time enforcement — SwiftSyntax can't tell 'is this another @CollaborationTools type' or 'does this thing have identity'. Docs-only fix.

---

## 22: RFC 0003: expose per-tool metadata (e.g. requiresApproval) for host-side gating

+++
status: closed
priority: low
kind: feature
labels: effort:s
depends: 14
created: 2026-07-13T01:03:09Z
updated: 2026-07-13T03:14:44Z
closed: 2026-07-13T03:14:44Z
+++

Derived tools frequently have side effects (delete, update, perform an intent). CollaborationKit intentionally leaves approval / gating to the host, but Slice 1 doesn't surface any metadata for a host to key off.

Missing per RFC 0003 open question 6:
- Attribute-level flag (e.g. requiresApproval) on @CollaborationTool.
- SwiftData bridge marks derived mutating tools (create/update/delete) automatically; AppIntents bridge marks intent execution similarly.
- Metadata exposed on AnyTool (or a companion struct) so a host UI can find it without re-inspecting Swift types.

- `2026-07-13T03:14:44Z`: Landed. Per-tool approval metadata:

- Tool protocol gains `var requiresApproval: Bool { get }` with a default of `false`.
- AnyTool now stores requiresApproval, propagating from the underlying Tool at erasure time.
- @CollaborationTool(_:name:requiresApproval:) accepts `requiresApproval:` and the macro emits it into the generated struct.

Wired into the demo: DemoNotes.delete opts in via `requiresApproval: true`. ChatSession collects the required-tool names and installs an approval closure that could prompt; today it auto-allows so the metadata still flows.

5 tests in RequiresApprovalTests: default false, macro-set true, combined with name override, host-side set construction, hand-written Tool default. Updated the 5 macro-expansion snapshots (#23) to include the new `var requiresApproval` line.

Pairs with #31 (approval enforcement mechanism).

---

## 23: RFC 0003: macro-expansion tests via SwiftSyntaxMacrosTestSupport

+++
status: closed
priority: high
kind: task
labels: effort:m
depends: 14
created: 2026-07-13T01:03:17Z
updated: 2026-07-13T02:10:29Z
closed: 2026-07-13T02:10:29Z
+++

Slice 1 tests exercise the macro through its runtime output (collaborationTools, call, LLMSession loop). There are no assertions against the actual expanded source, so regressions in codegen shape are only caught indirectly.

Missing per RFC 0003 open question 7:

- `2026-07-13T01:03:17Z`: Add SwiftSyntaxMacrosTestSupport-based expansion tests for CollaborationToolsMacro covering: empty type, single method, all supported parameter kinds, async/throws/actor call sites, and diagnostic-emitting cases (non-type target, unsupported parameter type).
- `2026-07-13T01:03:17Z`: Keep the runtime tests too; the two catch different bugs.
- `2026-07-13T02:10:29Z`: Landed 7 expansion tests using SwiftSyntaxMacrosTestSupport (via XCTest since assertMacroExpansion requires it): empty type, single method, actor await, throws, void return, custom-type parameter through the escape hatch, and diagnostic on unsupported metatype parameter. Runtime tests kept as-is — the two catch different bugs.

---

## 24: RFC 0003: expand built-in schema derivation to enums, tuples, and generic wrappers

+++
status: closed
priority: high
kind: enhancement
labels: effort:m
depends: 14
created: 2026-07-13T01:03:25Z
updated: 2026-07-13T02:16:41Z
closed: 2026-07-13T02:16:41Z
+++

Slice 1's built-in schema derivation covers primitives, Optional, Array, and [String: T]. Anything else falls through to CollaborationSchemaConvertible (#15) or errors.

RFC 0003 open question 1 asks how far the built-in derivation should go before requiring the escape hatch. Candidates to decide on:
- String-backed enums (map to 'enum' in JSON Schema).
- Enums with associated values.
- Tuples with labels.
- User-declared generic wrappers.

Whichever we support should have expansion tests and a clear line vs. the escape hatch.

- `2026-07-13T02:01:07Z`: Punt from autonomous run: this is a design decision, not an implementation task. The issue itself asks 'candidates to decide on' — string/int-backed enums, associated-value enums, labeled tuples, user-declared generic wrappers. Without knowing the target type's conformances at macro-expansion time (SwiftSyntax can't resolve conformances), the only safe path is either (a) a per-type annotation the user spells, or (b) route everything through CollaborationSchemaConvertible (#25). Recommend: land #25 first (explicit escape hatch), then reconsider what to bake in built-in. Meanwhile #41 covers RawRepresentable typed ids as its own targeted slice. Needs product call before implementation.
- `2026-07-13T02:16:41Z`: Resolved: the line is the escape hatch (#25 + #41 auto-conformance for RawRepresentable + primitives now conform out of the box). Enum-case value lists, tuples, and generic wrappers are all three-lines-of-code away from the escape hatch and don't warrant bespoke built-in derivation. If someone hits a real ergonomic wall on a specific case (e.g. CaseIterable enum sugar) they can file a targeted follow-up.

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
status: closed
priority: high
kind: feature
labels: effort:l
created: 2026-07-13T01:28:00Z
updated: 2026-07-13T06:41:55Z
closed: 2026-07-13T06:41:55Z
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
priority: medium
kind: feature
labels: effort:m, deferred
created: 2026-07-13T01:28:00Z
updated: 2026-07-13T15:15:05Z
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
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T01:28:00Z
updated: 2026-07-13T02:46:09Z
closed: 2026-07-13T02:46:09Z
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

- `2026-07-13T02:46:09Z`: Landed. Package.swift now declares .iOS(.v17). Changes:

- CredentialStore.init falls back to Application Support / collaborationkit/ on iOS (homeDirectoryForCurrentUser is unavailable there).
- collab-cli sources gated with #if os(macOS); on iOS the executable target compiles to a stub whose main() fatalErrors so linkage stays valid.
- CollaborationChatView.SettingsLink was already macOS-guarded.
- BrowserOpener, AttachmentThumbnailsView, Attachment already had UIKit paths under #if canImport(UIKit).

Verified: xcodebuild against a generic iOS Simulator destination builds the CollaborationKitUI scheme cleanly, and macOS 'swift build' + 76-test suite continue to pass.

---

## 29: CollaborationKitUI: tool-presenter registry for custom row content

+++
status: closed
priority: high
kind: feature
labels: effort:m
created: 2026-07-13T01:28:00Z
updated: 2026-07-13T14:25:13Z
closed: 2026-07-13T14:25:13Z
+++

Right now ConversationRowView renders every tool call the same way: icon + summary line + optional monospaced result. Rich hosts want per-tool custom content (e.g. Phosphor's compileShader row showing diagnostics inline, a diff view for edit results, an image preview for an image-gen tool).

Design a `ToolPresenter` protocol (or view builder closure) registered by tool name, consulted by ConversationRowView. Default presenter matches today's rendering. Registry lives on the store or in the environment; unknown tools fall through to the default.

Related: RFC 0002, #13.

---

## 30: CollaborationKitUI: accessibility pass

+++
status: closed
priority: medium
kind: task
labels: effort:m
created: 2026-07-13T01:28:00Z
updated: 2026-07-13T02:55:40Z
closed: 2026-07-13T02:55:40Z
+++

RFC 0002 open question 6: roles/labels for the transcript, streaming announcements, focus management on the composer.

Concretely:
- Transcript rows: accessibilityLabel per row kind (user prompt, assistant reply, tool call name+state, error).
- Streaming announcements: post an accessibility notification when a new item appears or a turn completes (VoiceOver rotor).
- Composer: sensible focus order; explicit labels on Attach/Send/Stop buttons; announce token label changes as polite updates.
- ContentUnavailableViews: audit systemImage roles.
- Dynamic Type: verify at accessibility sizes.

Related: RFC 0002, #13.

- `2026-07-13T02:55:40Z`: First pass landed. Changes:

- ConversationRowView: combined element with a role-specific accessibilityLabel (User message / Assistant reply / Tool <name>[, errored] / Error) and an accessibilityValue that reads the content, image count for user rows, tool summary + result-or-pending, and the round-trip latency when known.
- ComposerView: explicit accessibilityLabel and accessibilityHint on Attach / Send / Stop buttons (labels replace SF-symbol-derived defaults; hints describe the action).
- ComposerAttachmentsView: attachment thumbnails get a filename label; remove button gets an explicit label + hint.
- TranscriptView 'thinking' row: ignores its children and announces 'Assistant is generating a reply' as a single element so VoiceOver reads one thing.

Not touched this pass — happy to file follow-ups if you want them separate:
- VoiceOver rotor announcements when a new item appears (needs an AccessibilityNotification.post on transcript diff).
- Dynamic Type verification at accessibility sizes.

---

## 31: Tool approval

+++
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T01:34:27Z
updated: 2026-07-13T02:47:54Z
closed: 2026-07-13T02:47:54Z
+++

Add a mechanism for the host to approve (or deny) tool invocations before they run. Related to #22 (per-tool metadata like requiresApproval).

- `2026-07-13T01:50:12Z`: Related to #32 (path approval for built-in file tools) and #22 (per-tool requiresApproval metadata): #22 surfaces the flag, #31 defines the host-side hook that consumes it, #32 is a concrete built-in application of the same hook for filesystem paths.
- `2026-07-13T02:47:54Z`: Landed. LLMSession.init now takes an optional `approval: @Sendable (ToolUse) async -> ToolApprovalDecision` closure (defaults to allow-all). The gate runs before each tool invocation; a `.deny(reason:)` decision produces an `is_error` ToolResult carrying the reason so the model can adapt to a different plan. New public ToolApprovalDecision enum with .allow / .deny(reason:) and a .deny shorthand for the fallback message. 4 tests: default allow-all, deny with reason, empty-reason fallback, per-tool decision by inspecting the input.

---

## 32: Path approval

+++
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T01:34:27Z
updated: 2026-07-13T02:49:53Z
closed: 2026-07-13T02:49:53Z
+++

Add a mechanism for the host to approve (or deny) filesystem path access by built-in file tools (read/write/edit).

- `2026-07-13T01:50:12Z`: Related to #31 (general tool-approval mechanism). Filesystem-path gating for read/write/edit is arguably a specialization: consider implementing it as a built-in participant in whatever host-approval hook #31 lands.
- `2026-07-13T02:49:53Z`: Landed as PathPolicy in Sources/CollaborationKit/FileTools/PathPolicy.swift. The built-in file tools (ReadTool/WriteTool/EditTool) don't take path parameters — they're bound to a TextDocument at construction, so their filesystem reach is already the document the caller passed in. This issue's premise applies to *custom* file tools hosts build themselves: PathPolicy is the helper for that case.

API:
- PathPolicy(allowedRoots: [URL], allowsSymlinkEscape: Bool = false)
- policy.check(url) throws PathPolicyError if outside allowed roots
- policy.allows(url) — bool convenience
- policy.resolve(path: String) throws — resolves relative-to-first-root, absolute-as-supplied, then checks

Guardrails:
- Roots canonicalize on init (symlinks + .. resolved) so containment compares like against like.
- Path-component comparison catches sibling prefix attacks (/a/b vs /a/bar).
- allowsSymlinkEscape defaults to false, so symlinks inside a root pointing outside are denied.
- ../.. attacks caught by canonicalization.

Relationship to #31: use ToolApprovalDecision for whole-call gating (rate limit, user confirmation UI) and PathPolicy for per-argument filesystem-scope gating. Different layers.

9 tests: containment, sibling-prefix, symlink escape (both settings), resolve() variants, .. escape, empty-roots.

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
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T01:40:35Z
updated: 2026-07-13T02:52:13Z
closed: 2026-07-13T02:52:13Z
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

- `2026-07-13T02:52:13Z`: Landed as ModelPickerSection in Sources/CollaborationKitUI/Views/. Fetches models via CollaborationCredentials.listAvailableModels() (which itself uses ModelLister on the built provider), filters via a caller-customizable predicate (default drops non-chat families and dated snapshots), sorts by displayName, persists selection to UserDefaults under 'collaborationkit.model.<backend>'. Wired into CollaborationSettingsView so hosts get it by default. CollaborationCredentials gained: selectedModel, selectModel(_:for:), listAvailableModels(), modelDefaultsKey(for:); makeProvider(model:) now defaults to selectedModel when no override is passed. Also fixed an unused-binding warning in AnthropicOAuth from the retry landing.

---

## 35: CollaborationKitUI: session debug export (JSON)

+++
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T01:40:35Z
updated: 2026-07-13T02:54:13Z
closed: 2026-07-13T02:54:13Z
+++

Phosphor's ConversationExport bundles a full session snapshot (raw transcript, system prompt, model id, cumulative usage, last error, tool calls/results, and any host-specific state like current shader source) into a Codable JSON export, then hands it to .fileExporter.

Design:
- Codable SessionExport value covering: exportedAt, model id, system prompt, TokenUsage, lastError, [Message], and the projected [ConversationItem] transcript with per-row timing.
- ConversationStore.buildExport() async that gathers the LLMSession's authoritative messages/usage plus the projected items.
- FileDocument (or Transferable) conformance for .fileExporter usage.
- Extension point for hosts to attach domain payload (e.g. Phosphor's currentSource) via a generic parameter or a userInfo dictionary.

Blocks: any Phosphor migration onto CollaborationKitUI.
Related: RFC 0002, #13.

- `2026-07-13T02:54:13Z`: Landed. New public SessionExport value type (Codable + Sendable) in Sources/CollaborationKitUI/Transcript/. Shadow shape captures messages, transcript items, usage, lastError, plus caller-supplied model id and free-form userInfo dictionary for host-specific payload (e.g. Phosphor's shader source). Domain types (Message / ConversationItem / TokenUsage) stay Codable-free.

ConversationStore.buildExport(model:userInfo:) gathers the snapshot; SessionExport.jsonData() / jsonString() / decode(_:) handle serialisation with ISO8601 dates and sorted keys. Hosts wanting a Transferable/FileDocument wrap the Data themselves.

3 tests: round-trip through JSON, key-field presence, empty lastError.

---

## 36: CollaborationKitUI: image drop destination on the transcript

+++
status: closed
priority: high
kind: feature
labels: effort:s
created: 2026-07-13T01:40:35Z
updated: 2026-07-13T14:22:43Z
closed: 2026-07-13T14:22:43Z
+++

Phosphor's transcript accepts image file drops (URLs) directly onto the scroll area and routes them into the pending composer attachments. CollaborationKitUI's TranscriptView has no dropDestination — users must go through the paperclip importer.

Design:
- TranscriptView gains a dropDestination(for: URL.self) that funnels dropped files into the ComposerView's attachment list.
- ComposerView exposes a way to receive attachments programmatically (init/binding or a small controller).
- Handle security-scoped URL access.

Blocks: parity with Phosphor's drag-drop experience.
Related: RFC 0002, #13.

- `2026-07-13T06:19:05Z`: Related: #66 (paste) and #67 (drag) on the composer.

---

## 37: CollaborationKitUI: menu-command / focused-scene-value hooks

+++
status: open
priority: medium
kind: feature
labels: effort:s
created: 2026-07-13T01:40:35Z
updated: 2026-07-13T15:13:29Z
+++

Phosphor exposes actions (export debug info, stop generation, roll back) to the app menu via focusedSceneValue with typed FocusedValueKey values, so the File / Edit menus can trigger them contextually.

Design:
- Public FocusedValueKey types for the actions CollaborationKitUI can drive: exportSession, stopGeneration, rollBack (once rollback lands).
- A small Actions value type surfaced by CollaborationChatView / TranscriptView / ComposerView via focusedSceneValue.
- Documented pattern for hosts to add CommandMenu items that consume them.

Related: RFC 0002, #13, #26 (rollback), and the export issue above.

- `2026-07-13T15:17:09Z`: Investigated. `exportDebugLog` is already wired via `focusedSceneValue` (see `SessionDebugExport.swift`) — so the remaining scope is `stopGeneration` and `rollBack`.

Punting: rollback (#26) hasn't landed, so the full set can't be delivered together. Adding just `stopGeneration` also raises API-shape questions I don't want to decide unilaterally:

1. One `Actions` struct exposed as a single focused value, or a family of narrow single-action focused values (following the `exportDebugLog` pattern)?
2. Where does `stopGeneration` get installed — automatically by `CollaborationChatView`, or via an explicit modifier like `sessionDebugExport`?
3. Should the focused value carry the `ConversationStore` itself (letting host menus reach anything) instead of typed action values?

Can you steer on (1)–(3), or should this wait until #26 lands so the whole surface goes in at once?

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
status: closed
priority: high
kind: feature
labels: effort:m
created: 2026-07-13T01:52:23Z
updated: 2026-07-13T02:06:39Z
closed: 2026-07-13T02:06:39Z
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

- `2026-07-13T02:06:39Z`: Landed via a default extension on CollaborationSchemaConvertible for RawRepresentable types whose RawValue conforms to a new CollaborationRawValue protocol (String/Int/Double/Float/Bool ship with it). A caller-declared typed id is now:

    struct NoteID: RawRepresentable, Codable, CollaborationSchemaConvertible, Hashable {
        let rawValue: String
    }

— no schema boilerplate, works as-is on tool parameters (with correct schema derived from RawValue) and returns (Encodable does the rest). Added 4 tests covering string- and int-backed ids for both schema derivation and end-to-end call dispatch.

---

## 42: Increase test coverage

+++
status: closed
priority: medium
kind: task
labels: effort:l
created: 2026-07-13T02:02:44Z
updated: 2026-07-13T06:21:05Z
closed: 2026-07-13T06:21:05Z
+++

Test coverage across CollaborationKit is insufficient. Audit current coverage, identify uncovered code paths (especially in core sync/collaboration logic), and add tests to reach an acceptable coverage level.

---

## 43: SwiftUI review

+++
status: closed
priority: medium
kind: task
created: 2026-07-13T02:02:45Z
updated: 2026-07-13T03:52:58Z
closed: 2026-07-13T03:52:58Z
+++

Review SwiftUI code in CollaborationKit and Examples for correctness, modern API usage, and adherence to house rules. Areas to check include view identity, state ownership, ForEach usage, environment values, animations, and use of soft-deprecated APIs.

- `2026-07-13T03:52:58Z`: Superseded — review performed and findings/fixes landed as #48 (SwiftUI review: bugs, anti-patterns, and missing #Previews). Closing as done.

---

## 44: Swift concurrency review

+++
status: closed
priority: medium
kind: task
created: 2026-07-13T02:02:45Z
updated: 2026-07-13T03:52:58Z
closed: 2026-07-13T03:52:58Z
+++

Review Swift concurrency usage across CollaborationKit for correctness and modern API usage. Look for actor isolation issues, Sendable violations, task lifetime bugs, unstructured Task usage, MainActor misuse, and other async/await pitfalls.

- `2026-07-13T03:52:59Z`: Superseded — review performed and findings/fixes landed as #50 (Swift concurrency review: LLMSession actor reentrancy + smaller fixes). Closing as done.

---

## 45: Investigate using Apple Passwords API to retrieve Claude/OpenAI API keys

+++
status: closed
priority: low
kind: feature
labels: effort:s
created: 2026-07-13T02:07:18Z
updated: 2026-07-13T06:21:08Z
closed: 2026-07-13T06:21:08Z
+++

Explore whether the Apple Passwords API can be used to fetch stored API keys (e.g. Claude, OpenAI) instead of requiring the user to enter/store them separately. Feasibility unknown — Passwords API may not expose arbitrary secrets or non-website credentials.

---

## 46: Replace AnyTool type-erasure wrapper with existential `any Tool`

+++
status: closed
priority: medium
kind: enhancement
labels: effort:s
created: 2026-07-13T03:15:57Z
updated: 2026-07-13T15:03:16Z
closed: 2026-07-13T15:03:16Z
+++

`AnyTool` predates / duplicates Swift's built-in existential support. Now that the codebase can rely on `any Tool`, the hand-rolled wrapper is redundant.

## Proposed fix (per user)
Remove `AnyTool` and use `any Tool` at the call sites instead.

---

## 47: CollaborationKitUI: render assistant Markdown in the transcript

+++
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T03:26:28Z
updated: 2026-07-13T03:51:03Z
closed: 2026-07-13T03:51:03Z
+++

ConversationRowView currently renders assistant text as a plain Text view, so Markdown that the model emits (headings, bullet lists, code blocks, bold/italic, links, inline code) shows up as raw `# heading` / ```code``` / `**bold**` syntax rather than formatted output.

Design:
- Add a small MarkdownRenderer view (or protocol) that ConversationRowView uses for the .assistant kind.
- Baseline: SwiftUI's AttributedString(markdown:) covers inline formatting (bold, italic, code, links) with zero deps.
- Block-level: fenced code blocks with monospaced font + subtle background; simple bullet/numbered lists via a light parser; headings as bold + larger.
- Streaming-friendly: parse incrementally OR re-render on every delta (small enough for chat sizes; profile).
- Opt-out via ConversationRowView initializer parameter for hosts that want raw Text.
- Consider selectable behavior — keep textSelection(.enabled).

Related: RFC 0002, #13. Follow-up to the built-in transcript.

- `2026-07-13T03:51:03Z`: Landed inline markdown for assistant text: ConversationRowView.assistantContent now runs the text through AttributedString(markdown:, options: .inlineOnlyPreservingWhitespace) with a plain-text fallback for mid-stream parse failures. Covers bold, italic, `code`, links, strikethrough. Block-level (fenced code, headings, lists) is a separate follow-up when someone hits it — the SwiftUI-native inline path is enough for typical assistant replies.

---

## 48: SwiftUI review: bugs, anti-patterns, and missing #Previews

+++
status: closed
priority: medium
kind: task
labels: effort:m
created: 2026-07-13T03:30:30Z
updated: 2026-07-13T03:34:01Z
closed: 2026-07-13T03:34:01Z
+++

Full SwiftUI review of CollaborationKitUI + demo against the swiftui-specialist and swiftui-house-rules skills. Grouped by impact.

## Real bugs

- **`CollaborationCredentials.selectedModel` doesn't participate in Observation.** Computed property reads UserDefaults; `selectModel(_:)` writes UserDefaults but Observation never fires. Views reading `credentials.selectedModel` won't re-render. `ModelPickerSection` gets away with it via its own `@State selection` push; any "Current model: …" display would go stale.
- **`APIKeySection` uses `AnyView`** for its `footer` parameter. House rules explicitly forbid `AnyView` — switch to a `@ViewBuilder Footer: View` generic.
- **`APIKeySection.savedFlash` transition doesn't animate.** `.transition(.opacity)` is applied, but no `.animation(_:value:)` and the state change happens outside `withAnimation`. The "Saved" label pops instead of fading.
- **`ConversationRowView` tool-result background is `Color.black.opacity(0.04)`** — hard-coded black doesn't invert in dark mode; body reads black-on-dark. Replace with `.tertiary` / `.quaternary` / `.regularMaterial`.

## Anti-patterns

- **`AnthropicOAuthSection.isLoggedIn` is `@State` synced via `onAppear`.** Manual-sync anti-pattern. Make it a computed property reading `credentials.store.anthropicOAuthCredentials() != nil` (or surface it on `CollaborationCredentials` and observe there), and drop `syncLoginState()` altogether.
- **Multiple `.onChange` calls in `TranscriptView`** (items.count / isGenerating / lastItemContentLength) each calling `scrollToEnd`. Fold into one Equatable compound id.
- **`.help()` on Attach/Send/Stop buttons in `ComposerView`** is redundant with the newly-added `.accessibilityHint`. Pick one.
- **Segmented pickers in demo `NoteEditor` for tags (5 cases) and colors (7 cases)** are cramped. Use `.menu` (or `.palette`).

## Missing #Previews (house-rule violation)

Every new SwiftUI view must ship at least one `#Preview`. Currently missing:

Library:
- CollaborationChatView, TranscriptView, ConversationRowView
- ComposerView, ComposerAttachmentsView, AttachmentThumbnailsView
- APIKeySection, AnthropicOAuthSection, ModelPickerSection

Demo:
- All four (CollaborationDemoApp isn't a view, but ContentView, DemoNotes-adjacent views, NoteEditor, NotesListView are).

## House-style nits

- Hardcoded palette in `ConversationRowView` (`.indigo`, opacity literals) — already tracked as Theme #27.
- Demo `Editing` inline struct in ContentView reads awkwardly (verb-shaped noun); `EditingNote` is clearer.

Related: RFC 0002, #13, #27.

- `2026-07-13T03:34:01Z`: Landed. All items addressed:

Real bugs:
- CollaborationCredentials.selectedModel is now a stored, Observation-tracked var; `selectModel(_:)` updates it and `refresh()` re-reads from UserDefaults on backend switch.
- APIKeySection is now generic over a `@ViewBuilder Footer: View`; AnyView is gone. Convenience wrappers pass Link footers directly.
- APIKeySection.savedFlash now animates via `.animation(.smooth, value: savedFlash)` on the row HStack.
- ConversationRowView tool-result background uses `.quaternary` material instead of hardcoded black-opacity, so it inverts in dark mode.

Anti-patterns:
- AnthropicOAuthSection.isLoggedIn is now a computed property off credentials, dropping the @State mirror and `syncLoginState()` dance.
- TranscriptView folds three .onChange calls into a single Equatable ScrollSignal compound key.
- Redundant .help() calls on ComposerView Attach/Stop buttons removed (accessibilityHint covers them).
- Demo NoteEditor uses default (menu) pickers for tag/color instead of cramped segmented.

Missing #Previews added:
- Library: CollaborationChatView, TranscriptView, ConversationRowView, ComposerView (plain + glow), ComposerAttachmentsView, AttachmentThumbnailsView, APIKeySection, AnthropicOAuthSection, ModelPickerSection.
- Demo: ContentView, NotesListView (empty + populated), NoteEditor.

Nit: demo Editing → EditingNote.

107 tests + xcb build pass on both library and demo.

---

## 49: Skills support

+++
status: open
priority: medium
kind: feature
labels: effort:xl, deferred
created: 2026-07-13T03:33:06Z
updated: 2026-07-13T15:13:10Z
+++

CollaborationKit has no concept of skills — bundles of instructions (and optionally scripts/resources) the model can load on demand to specialize its behavior for a task.

Skills are used by pi and Claude Code to give the model context-specific guidance without bloating the system prompt. Without support, hosts that want the same pattern have to build it themselves on top of tools.

Scope to explore:
- How skills are discovered and registered on a session.
- Whether skills are surfaced as tools (model-invoked) or as prompt injection (harness-managed).
- Interaction with the existing tool loop and system prompt.
- Whether `CollaborationKitUI` needs a picker / indicator.

---

## 50: Swift concurrency review: LLMSession actor reentrancy + smaller fixes

+++
status: closed
priority: high
kind: task
labels: effort:s
created: 2026-07-13T03:38:48Z
updated: 2026-07-13T03:45:16Z
closed: 2026-07-13T03:45:16Z
+++

Review against the swift-concurrency-pro skill (Swift 6.2, strict concurrency). Ordered by impact.

## Real bugs

### Sources/CollaborationKit/Core/LLMSession.swift

- **Actor reentrancy in `send(_:)`.** Two concurrent `await session.send(...)` calls interleave: each appends its user message, both call `runLoop`, and both loops yield events onto the same `eventContinuation`. Consumers see mixed `.textDelta`s from turn A and turn B and cannot tell them apart. Hosts already serialize (e.g. ConversationStore guards on `isGenerating`), so a well-behaved caller never trips it — but the actor shouldn't rely on that convention.

  Fix: gate with a state flag and throw a new `SessionError.turnAlreadyInProgress` when a second call arrives while another is running.

- **Events stream never finishes.** `eventContinuation` is created in init and never terminated. Any `for await event in session.events` iterates for the process lifetime unless the caller cancels its own iteration Task. `close()` exists but no internal path calls it. Related to #4 (cancellation) but distinct — even a clean, non-cancelled shutdown never terminates the stream.

- **runLoop doesn't check Task.checkCancellation()** — already tracked as #4 (punted). Recording the link here so this review isn't the only place it lives.

## Style / small cleanups

### Sources/CollaborationKit/Core/Retry.swift

- Use `Task.sleep(for: .seconds(delay))` instead of `Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))`. The nanoseconds form is soft-deprecated.

### Sources/CollaborationKit/Anthropic/AnthropicOAuth.swift

- The `_ = http` no-op line in `exchange` is leftover from silencing an unused-binding warning during the retry refactor. Drop the `let http` binding entirely — the status check is sufficient.

## Verified non-issues

- StreamingTransport uses the standard AsyncThrowingStream + `onTermination = task.cancel()` pattern.
- ConversationStore's sendTask / eventTask capture `[weak self]`, cancel cleanly, and the `defer` cleanup runs on MainActor.
- TurnTimer (CLI) is a clean actor with no reentrancy risk.
- FileDocument / InMemoryDocument / CLICredentialStore use `@unchecked Sendable` legitimately (NSLock or documented-thread-safe base).
- Retry loops respect cancellation via Task.sleep.

- `2026-07-13T03:45:16Z`: Landed the four items:

- LLMSession actor reentrancy: guard `send` with an `isRunning` flag; concurrent send() calls now throw `SessionError.turnAlreadyInProgress` instead of interleaving onto the shared event stream. New regression test uses a gated provider to exercise the race.
- Retry.swift: `Task.sleep(nanoseconds:)` → `Task.sleep(for: .seconds(delay))`.
- AnthropicOAuth.exchange: dropped the leftover `if let http` + `_ = http` no-op from the retry refactor.

Left open: the 'events stream never finishes' item overlaps with #4 (task cancellation) — cleaner to solve them together when #4's design lands. Noting here so the review has one destination.

---

## 51: Demo: add an edit-note tool to DemoNotes

+++
status: closed
priority: low
kind: enhancement
labels: effort:s
created: 2026-07-13T03:41:23Z
updated: 2026-07-13T03:43:37Z
closed: 2026-07-13T03:43:37Z
+++

DemoNotes exposes list / search / create / setTag / setColor / delete. There's no way for the assistant to change a note's title or body once created — a create-and-forget model. Add an `edit` tool:

    @CollaborationTool("Edit an existing note's title and/or body. Nil fields leave the value unchanged.")
    func edit(id: Note.ID, title: String?, body: String?) async throws

Fills in the last obvious CRUD hole and gives the assistant a natural way to iterate on a note without deleting and recreating it (which changes the id and loses any tag/color).

- `2026-07-13T03:43:37Z`: Landed. New DemoNotes tool: `edit(id: Note.ID, title: String?, body: String?)`, nil fields leave the value unchanged. Uses the same `mutate` helper as setTag/setColor. System prompt updated to list edit alongside the other tools.

---

## 52: Architecture: pluggable Backend replacing the CollaborationBackend enum

+++
status: closed
priority: medium
kind: task
labels: effort:l
created: 2026-07-13T03:55:10Z
updated: 2026-07-13T03:59:58Z
closed: 2026-07-13T03:59:58Z
+++

**Cluster**: CollaborationBackend enum, KeychainCredentialStore.hasCredentials(for:) / makeProvider(for:model:maxTokens:), CollaborationCredentials.selectedModel / selectModel / listAvailableModels / modelDefaultsKey, ModelPickerSection.defaultChatModelFilter, CollaborationCredentialsError.

**Problem**: The three-case enum is a plug-in surface pretending to be an enum. Adding a fourth backend (Ollama, ds4, a custom gateway) requires editing 4–5 files. Backend knowledge is scattered:

- Enum: default model per backend, display name.
- KeychainCredentialStore extension: which slots to read, how to build the provider.
- CollaborationCredentials: selectedModel accessor, per-backend UserDefaults key.
- ModelPickerSection: chat-family filter heuristic per backend.

**Deepening**: A single `Backend` value type that owns its identifier, display name, default model, credential slot bindings (which Keychain accounts, how to construct AnthropicAuth / OpenAIConfig), and its chat-model filter. Hosts register the backends they want; `CollaborationCredentials` iterates them. CollaborationSettingsView / ModelPickerSection consult the registry instead of switching on the enum.

**Dependency category**: Composition / registration.

**Test impact**: One test suite per backend value rather than one big switch. Adding a backend becomes 'declare it and add it to your registry'; no library edits.

**Non-goals**: Doesn't change the wire encoding or the streaming plumbing (that's #53). Doesn't touch the CLI's ProviderKind (its config surface is different).

Ranking: highest AI-navigability payoff among the three architecture candidates. See the improve-codebase-architecture review.

- `2026-07-13T03:59:58Z`: Landed. New `Backend` value type in Sources/CollaborationKitUI/Backend.swift owns id, displayName, defaultModel, hasCredentials closure, makeProvider closure, modelFilter closure. Three built-in backends exposed as static factories: Backend.claudeSubscription, .anthropicAPI, .openAI (and Backend.allBuiltin).

Migration:
- Deleted CollaborationBackend enum + the KeychainCredentialStore extensions.
- CollaborationCredentials now takes `backends: [Backend]` on init (defaults to Backend.allBuiltin), stores the selected Backend value, and picks the right slot dynamically.
- CollaborationSettingsView.backends prop dropped; the picker iterates credentials.backends. Credential-section switch keyed by backend.id.
- ModelPickerSection uses backend.modelFilter directly; `filterOverride` closure available for one-off tweaks.
- CollaborationCredentialsError carries (id, displayName) so it doesn't pull the whole Backend value.

Adding a new backend now: one Backend(...) declaration in host code + pass it into CollaborationCredentials(backends:). No library edits, no enum case, no scattered switches. 6 BackendTests cover distinct ids, filters, custom backends, error rendering.

---

## 53: Architecture: unify AnthropicProvider + OpenAIProvider behind a WireProvider port

+++
status: closed
priority: medium
kind: task
labels: effort:l
created: 2026-07-13T03:55:10Z
updated: 2026-07-13T04:04:04Z
closed: 2026-07-13T04:04:04Z
+++

**Cluster**: AnthropicProvider, AnthropicWire, AnthropicProvider+StreamAccumulator, OpenAIProvider, OpenAIWire, OpenAIProvider+OpenAIStreamAccumulator, AnthropicConfig, OpenAIConfig — roughly 400 lines of parallel plumbing.

**Problem**: The two providers are shallow duplicates. Each owns URLSession + config, calls StreamingTransport.stream(...) with a per-wire accumulator, and builds URLRequests with auth headers. The wire encoding is a pure function per provider; the accumulators do the same job (buffer tool-call argument fragments and emit ProviderStreamEvents).

**Deepening**: A `WireProvider` protocol at the port:

    protocol WireProvider: Sendable {
        associatedtype Config
        var config: Config { get }
        func encodeRequestBody(messages: [Message], system: String?, tools: [ToolSpec]) -> JSONValue
        func authorizedRequest(url: URL, body: Data) async throws -> URLRequest
        func makeAccumulator() -> ServerSentEventSink
        func httpError(status: Int, body: String) -> Error
        func modelListURL() -> URL?
        func decodeModelList(_ json: JSONValue) throws -> [ModelInfo]
    }

Then a single `HTTPStreamingProvider<Wire: WireProvider>: ModelProvider, ModelLister` implements send / listModels once against StreamingTransport. AnthropicWire and OpenAIWire conform to WireProvider; the two Provider classes shrink to typealiases or thin wrappers.

**Dependency category**: Ports & adapters.

**Test impact**: Today's tests are parser-level (StreamAccumulatorTests, OpenAIStreamAccumulatorTests) — internal to each provider, and #1 (mock URLProtocol end-to-end) is still open because the boundary is fuzzy. With a WireProvider protocol, boundary tests can drive HTTPStreamingProvider once with a fake wire and cover both concrete providers through their WireProvider conformance instead.

**Non-goals**: No wire-format changes. Retry policy and StreamingTransport stay as-is.

Ranking: biggest raw duplication kill among the three candidates.

- `2026-07-13T04:04:04Z`: Landed. New `WireProvider` protocol in Sources/CollaborationKit/Core/WireProvider.swift refines ModelProvider + ModelLister with five wire-specific hooks (makeChatRequest, makeAccumulator, httpError, makeModelsRequest, decodeModels) plus urlSession + retryPolicy. Default implementations of send() and listModels() route through StreamingTransport once.

AnthropicProvider and OpenAIProvider now conform to WireProvider — the ~120 lines of send/listModels body from each shrunk to the wire-specific hooks. Total savings: about 100 lines of duplicated plumbing.

Made public so third-party wires can compose:
- ServerSentEventSink (was internal)
- StreamingTransport (was internal enum) + its stream/fetchJSON entry points

Added WireProviderTests: 4 boundary tests exercise the default send/listModels via a FakeWire + URLProtocol stub (serialized suite, shared static stubbed responses per path). Existing accumulator and provider tests untouched — still 114 tests plus 4 new ones for the boundary → 118 pass.

---

## 54: Architecture: split ConversationStore into MessageMirror + TranscriptProjection + Store

+++
status: closed
priority: low
kind: task
labels: effort:l
created: 2026-07-13T03:55:10Z
updated: 2026-07-13T04:10:47Z
closed: 2026-07-13T04:10:47Z
+++

**Cluster**: ConversationStore (442 lines). Currently owns LLMSession lifecycle, message mirroring, presentation metadata (timing / latency / summaries), streaming assistant overlay, error overlay, and projection to ConversationItems — six concerns fused in one @Observable @MainActor class.

**Problem**: Historical port from Phosphor. All six lived in one class because they all touched the shared `items` and `presentation` state, but the presentation side-table and streaming/error overlays don't have to share a home with the mirror. Result: there are no direct behavior tests for the store because touching one concern means constructing the world for all six.

**Deepening**: Three types.

- `MessageMirror`: a pure state machine that consumes SessionEvents and produces a canonical [Message] list plus a small `Overlays` struct (streamingText: String?, errors: [String], per-item timing). Value type, no SwiftUI dependency, unit-testable with plain assertions.
- `TranscriptProjection`: a pure function `([Message], Overlays) -> [ConversationItem]`. Also value-type, no @MainActor, no observation.
- `ConversationStore` (thin): @Observable @MainActor. Owns LLMSession, runs the event pump, holds the mirror + overlays, republishes items via the projection. Public surface stays the same so hosts don't notice.

**Dependency category**: Concerns fusion.

**Test impact**: Currently the store has effectively no unit tests — SessionExportTests is fixture-builder work, not behavior. After splitting, MessageMirror gets a full state-machine test suite (delta / tool call / result / cancellation events) and TranscriptProjection is pure-function testable. The thin store keeps its integration tests (of which there are none today either, but that's a smaller target).

**Non-goals**: Public API of ConversationStore stays as-is. No new UI. Rollback (#26) isn't in scope; it belongs on whatever owns the mirror.

Ranking: lowest urgency of the three architecture candidates but real testability payoff.

- `2026-07-13T04:10:47Z`: Landed. ConversationStore (was 442 lines) split into three types:

- **MessageMirror** (Sources/CollaborationKitUI/Transcript/MessageMirror.swift): pure Sendable value type. Consumes SessionEvents and maintains messages, streamingAssistantText, errorOverlays, and presentation metadata. No SwiftUI, no @MainActor, no observation. Unit-testable with plain assertions.
- **TranscriptProjection** (Sources/CollaborationKitUI/Transcript/TranscriptProjection.swift): pure enum with a static project(_:) function turning MessageMirror into ([ConversationItem], Set<ItemID>). Computes latency during projection from the previous row's end timestamp; no side-table needed for latency anymore.
- **ConversationStore** now a thin @Observable @MainActor shell (188 lines vs 442): owns LLMSession, event pump task, sendTask; delegates every event to mirror.handle then reprojects.

Public API unchanged: send/stop/cancel/items/messages/usage/lastError/isEmpty all still exist and behave identically.

New tests:
- MessageMirrorTests: 7 tests exercise user turn append, streaming delta accumulation, text finalization, tool call + result, error overlay ordering, tool call finishing the streaming overlay.
- TranscriptProjectionTests: 6 tests cover empty mirror, user prompt projection, assistant text with timing, tool call summary, latency-gap calculation, streaming overlay projection, error overlay ordering.

Total: 118 → 131 tests. macOS + demo xcb build clean.

---

## 55: @CollaborationTool in extensions: unsupported by Swift macros; document + diagnose

+++
status: closed
priority: low
kind: bug
labels: docs
created: 2026-07-13T04:04:01Z
updated: 2026-07-13T05:27:39Z
closed: 2026-07-13T05:27:39Z
+++

Marking a method with `@CollaborationTool` inside an `extension` of a `@CollaborationTools`-annotated type doesn't produce a working tool.

Expected: methods annotated in extensions are picked up the same way as methods declared in the primary type body, and appear in the generated `collaborationTools` array.

Actual: TBD — needs reproduction to confirm whether the peer macro is silently ignored, the member macro doesn't see extension members, or it fails to compile.

- `2026-07-13T04:13:43Z`: Investigated. Root cause is a Swift macro limitation, not our bug — @attached(member) macros only see the primary type's member block, not extensions. There's no clean workaround:

- Peer macros can't add conformances to the enclosing type (rules out runtime discovery via a protocol registry).
- Mirror can't enumerate nested types (rules out reflection-based collection).
- Static composition (`Self._ckExtTools_XYZ`) forces the primary type to enumerate every extension by hand — worse than just inlining the tools.

Reduced to a documentation + diagnostics task:

- (docs) @CollaborationTools doc comment: state that @CollaborationTool must be declared in the primary type body; extension methods are silently skipped.
- (diagnostic, harder) Ideally a diagnostic when @CollaborationTool appears in an extension of a type that has @CollaborationTools elsewhere. The peer macro doesn't get told about the enclosing @CollaborationTools context though, so this is best-effort — could at least emit a warning saying 'this only works when the enclosing type is @CollaborationTools-annotated in the SAME declaration.'
- (revisit) Reopen the codegen path if Swift ever gains cross-extension macro visibility.

Kept open at low priority for the docs + optional diagnostic work.

- `2026-07-13T05:27:39Z`: Not fixable: Swift attached-member macros can't see extension members. Documented in the @CollaborationTools doc comment and a new README FAQ section.

---

## 56: Wire encode and decode for each provider live in unrelated modules

+++
status: closed
priority: low
kind: task
labels: architecture, effort:m
created: 2026-07-13T04:20:54Z
updated: 2026-07-13T04:53:04Z
closed: 2026-07-13T04:53:04Z
+++

Each provider translates between the neutral `Message` model and its own wire format in two halves that live apart:

- Anthropic: `AnthropicWire` (encode) + `StreamAccumulator` inside `AnthropicProvider.swift` (decode).
- OpenAI: `OpenAIWire` (encode) + `OpenAIStreamAccumulator` inside `OpenAIProvider.swift` (decode).

They are inverse halves of one concept — "translate messages ↔ the wire for provider X" — but the split lives across two files per provider, wired together by the 5-method `WireProvider` protocol (`makeChatRequest`, `makeAccumulator`, `httpError`, `makeModelsRequest`, `decodeModels`).

Consequences:

- There is nowhere to write a round-trip test that asserts "these neutral messages, sent through provider X's encode + decode, come back as this event sequence." `AnthropicWireTests`, `StreamAccumulatorTests`, and `OpenAITests` each cover only a half.
- The `WireProvider` protocol has to expose separate seams for encode and decode because they live in separate types, so it's wider than it needs to be.
- Changes that touch the neutral model (a new `ContentBlock` case, tool approval metadata, etc.) require edits in four unrelated files.

Related: #9 covers the encode half only. This issue is the superset.

---

## 57: Backend/Credentials/Keychain layering only supports the concrete Keychain store

+++
status: closed
priority: low
kind: task
labels: architecture, effort:l
created: 2026-07-13T04:20:57Z
updated: 2026-07-13T04:52:39Z
closed: 2026-07-13T04:52:39Z
+++

The credentials layer is spread across three modules that all cross each other's boundaries:

- `Backend` (in `CollaborationKitUI/Backend.swift`) claims to be a pluggable value-type registry, but every closure it holds (`hasCredentials`, `makeProvider`) takes `KeychainCredentialStore` concretely. A custom `Backend` cannot use a different credential source.
- `KeychainCredentialStore` (a persistence type) exposes `anthropicOAuthTokenProvider(oauth:)`, which orchestrates read + expiry check + HTTP refresh via `AnthropicOAuth` + re-persist. The store is doing two jobs (Keychain persistence and OAuth refresh orchestration).
- `CollaborationCredentials` is `@Observable` state that only works with `KeychainCredentialStore`; its `makeProvider(model:maxTokens:)` delegates to `Backend`, which delegates back to the store.

Consequences:

- There is no way to run these types against an in-memory credential source. Tests either hit the real Keychain or work around the store entirely. `BackendTests` covers the built-in backends but only by constructing a real `KeychainCredentialStore` and cleaning up after itself.
- Adding a new credential source (env-var for the CLI, in-memory for tests, a different secure store) requires either editing every built-in `Backend` value or subclassing the concrete store.
- Adding a new backend requires touching `Backend`, `KeychainCredentialStore` (for named-slot accessors), and `CollaborationCredentials` (for model persistence keys).
- The layered flow "read stored credentials → refresh if expired → persist → build provider → issue request" is glued together by a chain of closures captured across three types, so it's hard to reason about as one operation.

The abstraction the code presents (pluggable `Backend`) is not the abstraction the code actually supports (Keychain-only backends). Either the pluggability is real or it should be dropped.

---

## 58: SessionExport shadow types silently drop new domain fields

+++
status: closed
priority: low
kind: task
labels: architecture, effort:m
created: 2026-07-13T04:21:00Z
updated: 2026-07-13T04:40:14Z
closed: 2026-07-13T04:40:14Z
+++

`SessionExport` (in `CollaborationKitUI/Transcript/SessionExport.swift`, 233 lines) is a hand-maintained parallel schema for every serialisable domain type in the package:

- `MessageExport` shadows `Message`
- `ContentBlockExport` shadows `ContentBlock`
- `ToolCallExport` shadows `ToolCall`
- `ToolResultExport` shadows `ToolResult`
- `ItemExport` shadows `ConversationItem`
- `UsageExport` shadows `TokenUsage`

Each shadow struct is paired with a hand-written `init(from:)` mapper.

The stated reason for the shadows is to keep wire-level `Codable` off the domain types. The cost is that any new field on `Message`, `ContentBlock`, `ToolCall`, `ToolResult`, `ConversationItem`, or `TokenUsage` silently disappears from exports until someone edits `SessionExport` in a second commit — and there is no test that fails when this happens.

Consequences:

- `SessionExportTests` (58 lines) can only assert on hand-picked fields; there is no golden-JSON test that would catch a dropped field.
- Every domain-model change carries an invisible obligation to update the export shadow. In practice this obligation gets forgotten.
- The friction is pure duplication with no compile-time link between the halves.

## Direction

Delete the shadow types. Put `Codable` directly on `Message`, `ContentBlock`, `ToolCall`, `ToolResult`, `ConversationItem`, and `TokenUsage` with hand-written `init(from:)` / `encode(to:)` where the on-disk shape needs to differ from the in-memory shape. Add a round-trip test so a dropped field fails the build.

See the `swift-no-shadow-types` skill.

- `2026-07-13T04:40:14Z`: Deleted the shadow types in SessionExport (MessageExport, ContentBlockExport, ToolCallExport, ToolResultExport, ItemExport, UsageExport). Added Codable directly to Message, ImageContent, ToolUse, ToolResult, ToolCall, ContentBlock, TokenUsage, ConversationItem, ItemID, and Kind. SessionExport now stores domain types directly (233 -> 92 lines). Added round-trip tests that fail if a new field is added without wiring.

---

## 59: Credential layer is shallow: fixed-slot CredentialStore protocol undercuts Backend extensibility

+++
status: closed
priority: high
kind: enhancement
labels: architecture, effort:l
created: 2026-07-13T05:06:25Z
updated: 2026-07-13T06:36:31Z
closed: 2026-07-13T06:36:31Z
+++

CredentialStore has 9 methods hard-coding three slots (anthropicKey/openAIKey/anthropicOAuth) as read/save/clear trios. Every new backend requires widening the protocol and all four conformers (InMemoryCredentialStore, KeychainCredentialStore, CLICredentialStore, test fakes), contradicting the Backend docs' claim that adding a backend is 'one value declaration — no library edits'. Seven files co-own 'am I signed in' (CredentialStore, InMemoryCredentialStore, KeychainCredentialStore, CLICredentialStore, CollaborationCredentials, Backend closures, AnthropicOAuth). The KeychainReadResult typealias fossil shows this seam has already shifted once. Keychain and CLI conformers have no tests.

---

## 60: Transcript pipeline duplicates the message-history reducer; risky orchestration in ConversationStore is untested

+++
status: closed
priority: high
kind: enhancement
labels: architecture, testing, effort:xl
created: 2026-07-13T05:06:25Z
updated: 2026-07-13T16:29:22Z
closed: 2026-07-13T16:29:22Z
+++

LLMSession.history and MessageMirror each independently implement 'append assistant blocks, attach tool result by toolUseID' (LLMSession.attachResult vs MessageMirror.attachResultToMirror/appendToolUseToMirror) with different merge rules — a latent divergence seam. Understanding one model turn requires bouncing across six files (LLMSession → SessionEvent → ConversationStore → MessageMirror → TranscriptProjection → views). The pure parts (MessageMirror, TranscriptProjection) are unit-tested, but the risky logic is untested: ConversationStore event-pump ordering (startPump races vs send appending directly to the mirror), reproject() mutating mirror.compact, cancellation/'Stopped.' overlay handling, and usage apparently accumulated twice (from .usage events in handle() and re-read from session.totalUsage in run()). No test constructs ConversationStore against a fake ModelProvider end-to-end. Related: issue #10 (runLoop decomposition) and #7 (history compaction) will stress this dual-history seam.

- `2026-07-13T16:29:22Z`: Fixed: session emits authoritative history snapshots via new SessionEvent.historyChanged; MessageMirror no longer reduces per-block events into messages. Added end-to-end orchestration tests exercising ConversationStore against a fake ModelProvider. Removed the store.usage double-count race.

---

## 61: Provider construction logic duplicated between Backend (UI target) and collab-cli; OAuth spoofing constants split across three files

+++
status: closed
priority: high
kind: enhancement
labels: architecture, effort:m
created: 2026-07-13T05:06:25Z
updated: 2026-07-13T06:29:42Z
closed: 2026-07-13T06:29:42Z
+++

Backend lives in CollaborationKitUI although it is a provider-registry concept, so collab-cli cannot import it and re-derives makeProvider logic by hand in Chat.run(). Credential errors are split across targets (CollaborationCredentialsError in UI's Backend.swift, AnthropicOAuthTokenError in core). The fragile Anthropic OAuth external contract has three owners: AnthropicWire.claudeCodeIdentity, AnthropicProvider.oauthBetas/oauthUserAgent/x-app headers, and AnthropicOAuth. Backend itself is a struct of 4 public closures exposing its entire implementation strategy; the actual work is in internal helpers (readAPIKey, model filters).

---

## 62: FileTools hand-writes JSON schemas the @CollaborationTools macro automates; tool call() bodies untested

+++
status: closed
priority: high
kind: enhancement
labels: architecture, testing, effort:m
created: 2026-07-13T05:06:25Z
updated: 2026-07-13T06:32:19Z
closed: 2026-07-13T06:32:19Z
+++

FileTools.swift predates the @CollaborationTools macro (RFC 0003) and hand-declares name/description/inputSchema/call for each tool, giving an interface/implementation ratio near 1:1. The Read/Write/EditTool call() bodies are untested (e.g. EditTool's uniqueness counting via components(separatedBy:)); only PathPolicy has test coverage.

---

## 63: Demo app doesn't wire up tool approval

+++
status: closed
priority: medium
kind: task
labels: effort:m
created: 2026-07-13T04:58:55Z
updated: 2026-07-13T14:45:11Z
closed: 2026-07-13T14:45:11Z
+++

DemoNotes marks delete as requiresApproval: true, but the demo's LLMSession is created without an approval closure, so the default allow-all applies and approval-gated tools run without any user prompt. The demo has no UI for approving/denying tool calls.

---

## 64: Composer is disabled while assistant is responding; queue prompts instead

+++
status: closed
priority: high
kind: feature
labels: effort:m
created: 2026-07-13T05:44:43Z
updated: 2026-07-13T14:29:49Z
closed: 2026-07-13T14:29:49Z
+++

During an active conversation turn (assistant streaming, tools running, etc.) the composer input is locked. The user has to wait for the whole turn to finish before typing the next prompt.

Instead, allow typing at any time and queue up prompts. When the current turn finishes, dequeue and send the next one automatically.

---

## 65: Empty-conversation placeholder shows hard-coded instructions that don't match most apps

+++
status: closed
priority: high
kind: enhancement
labels: effort:s
created: 2026-07-13T05:44:57Z
updated: 2026-07-13T06:25:46Z
closed: 2026-07-13T06:25:46Z
+++

The empty-conversation placeholder view renders a fixed instructional string. It's baked into CollaborationKit rather than provided by the host app, so it's wrong for the ~99% of integrations whose UI, tools, and workflow don't match what the placeholder describes.

The placeholder text (and probably the whole placeholder view) needs to be host-configurable, with a sensible generic fallback — or removed entirely and left to the host.

---

## 66: Composer doesn't accept pasted images or file attachments

+++
status: open
priority: high
kind: feature
labels: effort:m, deferred
created: 2026-07-13T05:57:23Z
updated: 2026-07-13T14:52:22Z
+++

Pasting an image (or any file) into the composer's text field does nothing. Users have no way to attach visual/document content to a prompt short of describing it in words.

The composer should accept pasted images and file attachments from the clipboard, surface them as attachment chips in the composer, and include them in the outgoing message.

- `2026-07-13T06:19:05Z`: Related: #67 (drag attachments on composer) and #36 (image drop on transcript).
- `2026-07-13T14:38:02Z`: Autonomous run 2: attempted onPasteCommand(of: [.image, .fileURL]) on the container, then moved to the TextField, then tried .pasteDestination(for: URL.self) + .onPasteCommand(of: [.image]) on the container. In all cases the focused TextField still wins for URL/text pastes and the attachment strip stays empty. Paste code left in place as scaffolding.

Next step likely needs a lower-level intercept — a custom NSTextView subclass that overrides paste:, or wrapping the composer in an NSViewRepresentable with pasteboardTypes. Not autonomous-friendly.

---

## 67: Composer doesn't accept dragged images or file attachments

+++
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T05:57:24Z
updated: 2026-07-13T14:14:34Z
closed: 2026-07-13T14:14:34Z
+++

Dragging an image or file onto the composer's text field does nothing. Users can't drop a screenshot, PDF, or other document onto the input to attach it.

The composer should accept dragged images and file attachments, surface them as attachment chips in the composer, and include them in the outgoing message.

- `2026-07-13T06:19:05Z`: Related: #66 (paste attachments on composer) and #36 (image drop on transcript).

---

## 68: Redesign the demo Settings window — current layout doesn't feel like a native macOS Settings scene

+++
status: closed
priority: medium
kind: none
created: 2026-07-13T05:58:52Z
updated: 2026-07-13T06:16:19Z
closed: 2026-07-13T06:16:19Z
+++

The CollaborationDemo Settings window is styled as three floating rounded 'cards' (AI SERVICE / OPENAI API CONFIGURATION / MODEL SELECTION) with all-caps section labels above each card, over a flat gray background. It reads as a bespoke landing page, not a macOS Settings window.

Problems visible in the current layout:
- Three separate cards for what is really one short form — lots of vertical whitespace and repeated chrome for very few controls.
- All-caps hovering section headers don't match macOS Settings conventions.
- The API Key row mixes a secure field, a 'Clear' button and a primary 'Save' button inline — the Save affordance implies unsaved state that doesn't otherwise exist elsewhere in Settings.
- The 'Get an API key' link is embedded inside the API key card as a full-width row, which reads as another setting rather than help text.
- Provider / Model pickers, API key, and a version footer are all fighting for equal visual weight.
- No use of the standard macOS Settings scene / tab layout even though there are obvious groupings (provider, credentials, model).

The Settings surface should look and behave like a native macOS Settings window and stop trying to be its own visual system.

- `2026-07-13T06:16:19Z`: Redesigned to match the mockup: AI Service section now has a header, API Key row is a single LabeledContent (SecureField + Clear + prominent Save) with status messages on a conditional second row, Model Selection header renamed, and the demo Settings scene picks up a version footer read from CFBundleShortVersionString.

---

## 69: Consider using a WebView for the conversation view

+++
status: open
priority: medium
kind: feature
labels: effort:l, deferred
created: 2026-07-13T05:59:52Z
updated: 2026-07-13T15:13:34Z
+++

The current conversation view has limited text selection and other interaction affordances. Investigate rendering the conversation as a WebView to get better native selection, copy, find, and rich-content rendering.

---

## 70: ComposerView: no way to show a backend/model header

+++
status: closed
priority: high
kind: enhancement
labels: effort:s
created: 2026-07-13T06:13:38Z
updated: 2026-07-13T14:19:01Z
closed: 2026-07-13T14:19:01Z
+++

Phosphor's composer shows a small caption above the prompt field: "cpu · <Backend display name> · <selected model id>". CollaborationKit's `ComposerView` has no slot for this and no built-in rendering of the active backend/model.

Hosts currently have to fork the whole composer to add it.

---

## 71: CollaborationChatView: no onGeneratingChange callback

+++
status: closed
priority: high
kind: enhancement
labels: effort:xs
created: 2026-07-13T06:14:12Z
updated: 2026-07-13T06:24:31Z
closed: 2026-07-13T06:24:31Z
+++

Phosphor's GeneratePanel takes an `onGeneratingChange: (Bool) -> Void` closure and fires it via `.onChange(of: store.isGenerating)`, so the host can react (disable UI, pause compilation, etc.) when a turn starts or ends.

`CollaborationChatView` has no equivalent hook. Hosts have to observe `store.isGenerating` themselves from outside.

---

## 72: CollaborationKitUI: built-in UI for session debug export

+++
status: closed
priority: medium
kind: enhancement
labels: effort:m
created: 2026-07-13T06:14:17Z
updated: 2026-07-13T15:06:36Z
closed: 2026-07-13T15:06:36Z
+++

#35 landed the `SessionExport` data model and `ConversationStore.buildExport(model:userInfo:)`, but hosts still have to hand-wire the UI to trigger it.

Phosphor's composer adds a ladybug button that calls `buildExport`, wraps the result in a `Transferable`, and presents `.fileExporter`. It also publishes an `ExportDebugLogAction` via `focusedSceneValue` so a File menu command can invoke the same export.

Missing surface in CollaborationKitUI:
- Optional composer affordance to run the export (with defaultFilename hook).
- A FocusedValueKey / focused-scene-value so hosts can add a File menu command that triggers export without reimplementing the plumbing.

---

## 73: Persist conversations across launches

+++
status: open
priority: medium
kind: feature
labels: effort:l, deferred
created: 2026-07-13T06:39:46Z
updated: 2026-07-13T15:12:40Z
+++

Conversations are not persisted; relaunching the app loses all prior conversation state. Should reload existing conversations on launch.

---

## 74: Dragging an image onto the composer text field pastes the file path as text

+++
status: open
priority: high
kind: bug
labels: effort:m, deferred
created: 2026-07-13T14:38:28Z
updated: 2026-07-13T15:11:44Z
+++

Dragging an image file from Finder onto the composer's TextField inserts the file path as literal text into the prompt, instead of attaching the image.

Dragging the same image onto the transcript area works correctly (routes into the composer's attachment strip via #36's drop destination).

## Repro
1. Open the demo app.
2. Drag an image file from Finder onto the composer TextField (not the transcript, and not the paperclip button).
3. Observe: the file path (e.g. /Users/…/screenshot.png) appears as text in the prompt field.

## Expected
The image is added to the composer's attachment strip, matching the transcript-drop behavior.

## Notes
Related: #66 (paste has the same underlying cause — focused TextField wins over container-level drop/paste destinations for URL/text payloads). #36 wired the transcript drop but did not extend the drop destination to the composer itself.

---

## 75: ComposerView: send/queue arrow visible while generating even when the field is empty

+++
status: closed
priority: medium
kind: enhancement
labels: effort:xs
created: 2026-07-13T14:39:23Z
updated: 2026-07-13T15:16:28Z
closed: 2026-07-13T15:16:28Z
+++

While a response is generating, the composer shows both a stop button and a send/queue arrow. The arrow stays visible even when the prompt field is empty, so there's nothing to queue.

## Expected
The send/queue arrow only appears while generating if the user has typed something (or added an attachment). When the field is empty, only the stop button shows.

## Notes
Introduced by #64 (queue prompts while assistant responding).

- `2026-07-13T15:16:28Z`: Hide the send/queue arrow while generating when the composer is empty; only the stop button remains.

---

## 76: Tap attachment to view it

+++
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T14:44:13Z
updated: 2026-07-13T15:18:35Z
closed: 2026-07-13T15:18:35Z
+++

In the chat UI, tapping an attachment should open/preview it. Currently there's no way to view an attachment after it's been sent.

- `2026-07-13T15:18:35Z`: Tapping a transcript attachment thumbnail now opens a full-size preview sheet with a Done button.

---

## 77: Review uses of stringy keys

+++
status: closed
priority: medium
kind: task
labels: effort:m
created: 2026-07-13T15:02:13Z
updated: 2026-07-13T15:24:38Z
closed: 2026-07-13T15:24:38Z
+++

Audit the codebase for places where we use bare String keys (UserDefaults keys, Keychain account names, Codable CodingKeys spelled as raw strings, dictionary keys, notification names, etc.) and evaluate whether they should be strongly-typed instead.

Areas to look at:
- `UserDefaults` `forKey:` call sites (e.g. `CollaborationCredentials`, backend model/default keys)
- Keychain `kSecAttrAccount` values in `KeychainCredentialStore`
- Any `[String: Any]` payload dictionaries
- Backend/provider identifiers passed around as `String`
- Any other ad-hoc string constants used as lookup keys

For each site, note whether a typed wrapper (e.g. a `RawRepresentable` key type, dedicated enum, or `KeyPath`-based API) would prevent typos, collisions, or drift between read/write sites.

- `2026-07-13T15:24:38Z`: Audit posted; applied the one small fix it recommended (deduping built-in Backend id/displayName strings into a private `Builtin` enum in Backend.swift).
- `2026-07-13T15:24:42Z`: # Stringy-key audit (issue #77)

Scanned: `UserDefaults` call sites, Keychain `kSecAttr*` usage, `[String: Any]` payloads, `CodingKeys`, backend/provider identifiers, and other lookup-key strings across `Sources/`.

## UserDefaults

- `CollaborationCredentials(defaultsKey: "collaborationkit.backend")` — public init parameter, default lives in one place. No drift risk.
- `Backend.modelDefaultsKey` — computed as `"collaborationkit.model.\(id)"` on `Backend`; all four call sites in `CollaborationCredentials.swift` route through the property. No magic strings scattered.
- `CLICredentialStore.defaultsKey(for:)` — CLI-local helper, one derivation site.

**Verdict:** already centralized. No change needed.

## Keychain

- `KeychainCredentialStore` account values flow from `CredentialStoreKey.anthropicAPIKey/anthropicOAuth/openAIAPIKey` (with `CredentialStore.StandardKey` alias). Callers don't spell raw account strings.
- `kSecClass`/`kSecAttrService`/`kSecAttrAccount`/`kSecValueData` etc. are `CFString` constants bridged via `as String` — that's the idiomatic Security API surface, not a stringy-key smell.
- `[String: Any]` query dictionaries are required by `SecItemCopyMatching`/`SecItemAdd`/`SecItemUpdate`; can't be typed further without a wrapper that offers nothing but ceremony.

**Verdict:** already keyed off `CredentialStoreKey`. No change needed.

## Codable / CodingKeys

- `ConversationItem` and `Message` use `enum CodingKeys: String, CodingKey`. The strings are wire-format identifiers (`type`, `uuid`, `text`, `images`, `name`, …) — they must be raw strings by design.
- Nested tag enums (`Kind`, `Tag`) are `String, Codable` so the on-wire discriminator is spelled exactly.

**Verdict:** correct pattern; no action.

## Backend / provider identifiers — the one real smell

`Backend`'s three built-ins (`claudeSubscription`, `anthropicAPI`, `openAI` in `Backend.swift`) each spell their id twice:

```
static let anthropicAPI = Backend(
    id: "anthropicAPI",                     // <-- here
    ...
    makeProvider: { store, model, ... in
        let key = try Backend.readAPIKey(
            store.anthropicAPIKey(),
            id: "anthropicAPI",             // <-- and again
            displayName: "Anthropic API"
        )
        ...
    }
)
```

The `makeProvider` closure is initialized before the `Backend` value exists, so it can't reach `self.id`. If someone renames a built-in id, they have to update both spellings or the error payload silently drifts from the runtime id.

**Options:**
1. Extract each built-in id into a `private enum BuiltinBackendID { static let anthropicAPI = "anthropicAPI"; … }` and reference it from both places.
2. Move the `readAPIKey` call to a small helper that receives the `Backend` and reads `.id`/`.displayName` off it (requires post-init construction — could be a static factory method that returns a `Backend` from separate closures).
3. Leave as-is and add a debug assertion in `init` that the closures don't reference a stale id (hard to check statically).

Option 1 is small and mechanical; recommend that if we do anything here.

## Everything else scanned

- `ClaudeCodeIdentity.userAgent/.betas/.app` — centralized string constants used from one call site each.
- `AnthropicConfig.apiVersion: String` — value comes from the caller; a `RawRepresentable` wrapper would add ceremony without shrinking the API surface.
- `[String: String]` in `SessionExport.userInfo` and `AnthropicOAuth` request bodies — genuinely open string bags by design.
- No `NotificationCenter` / `Notification.Name` usage anywhere in `Sources/`.
- Model ids (Anthropic/OpenAI) pass through as `String` — that matches how the wire APIs treat them; wrapping them in a phantom type would fight the servers' own vocabulary.

## Summary

Everything the issue named is already typed except the built-in `Backend` id duplication. Recommend a small follow-up to extract the three built-in id strings into a private `enum` and reuse them from both the `id:` and the `readAPIKey(id:)` call. All other stringy-key sites are either centralized via `CredentialStoreKey` / `Backend.modelDefaultsKey`, imposed by wire formats, or imposed by system frameworks (Keychain, Security).

---

## 78: Show tokens/% remaining until compaction

+++
status: closed
priority: medium
kind: feature
labels: effort:s
depends: 92
created: 2026-07-13T15:10:34Z
updated: 2026-07-13T16:29:55Z
closed: 2026-07-13T16:29:55Z
+++

The composer should display how many input tokens have been consumed relative to the compaction threshold (e.g. `12.3k / 100k`), so users see how close they are to a compaction event.

Depends on #92 (compaction strategies count tokens, never messages) landing first, so there's a single, well-defined token budget to display.

Once #92 lands:

- `KeepRecentCompactionStrategy` has a required `triggerAtTokens` — that's the denominator.
- Progress = `usage.inputTokens / triggerAtTokens`.
- Extend `CompactionStrategy` with a `compactionProgress(usage:)` hook returning an optional `CompactionProgress` (current, limit). `NoCompactionStrategy` returns nil. `KeepRecentCompactionStrategy` returns the pair above.

Remaining open question: **UI placement.** Suggested default: a small caption chip in `ComposerView`'s actions row, next to the existing token label — hidden when the strategy returns nil so hosts using `NoCompactionStrategy` see nothing.

- `2026-07-13T15:11:44Z`: Related to #7 (compaction landed Jul 12). Depends on the strategy exposing a 'progress toward compaction' signal — currently KeepRecentCompactionStrategy triggers on message count, not tokens, so the UI would need either a token-budget strategy or a strategy-agnostic 'how close am I' hook.
- `2026-07-13T15:17:32Z`: Punting: the current `KeepRecentCompactionStrategy` triggers on message count, not tokens, so there's no natural 'tokens until compaction' number to show. To resolve this we'd need to (a) extend `CompactionStrategy` with a `progressTowardCompaction(history:usage:)` hook, (b) decide what 'progress' means for a count-based strategy (message count?), and (c) decide where the UI displays it (composer action row? a separate chip?). Those are three API/design decisions that need your call before writing code.
- `2026-07-13T15:51:34Z`: Reframed: message-count fallback dropped (see #92). The strategy-progress API question is trivial now — only UI placement remains.
- `2026-07-13T16:29:55Z`: Landed together: KeepRecentCompactionStrategy is now token-triggered only (triggerAtTokens required, minMessagesBeforeCompacting removed), and CompactionStrategy gains a compactionProgress(usage:) hook that KeepRecent implements. ConversationStore surfaces it as compactionProgress; ComposerView renders a 'used / limit' chip that hides itself when the strategy has no budget.

---

## 79: Built-in tools suite (read, write, search, etc.)

+++
status: closed
priority: medium
kind: feature
labels: effort:l
created: 2026-07-13T15:19:12Z
updated: 2026-07-13T15:59:52Z
closed: 2026-07-13T15:59:52Z
+++

CollaborationKit should ship a suite of built-in tools (file read, file write, search, and similar common tools) that users can enable and configure on a session.

Tools must be opt-in: nothing runs unless the host app explicitly enables and configures it (e.g. allowed paths, allowed operations, size limits).

Scope to define:

- `2026-07-13T15:19:12Z`: Which tools are in the initial set.
- `2026-07-13T15:19:12Z`: Configuration surface per tool (allowlists, sandbox roots, limits).
- `2026-07-13T15:19:12Z`: How host apps enable/disable them per session or per conversation.
- `2026-07-13T15:26:46Z`: Related to #80 (web tool candidate for the built-in tools suite).
- `2026-07-13T15:42:10Z`: Reviewed. Punting: the issue explicitly leaves three decisions open (which tools ship in the initial set, per-tool config surface for allowlists/sandbox roots/limits, and the host enable/disable UX per session vs. per conversation). These are policy calls I don't want to make unilaterally on an effort:l feature, and picking the wrong shape here has a large blast radius for downstream tools (#80, etc.). Can you decide the initial set (e.g. just read+write scoped to a caller-supplied directory?) and the enable/config API shape? I'd suggest splitting into: (a) a small 'ToolPolicy'/allowlist type in CollaborationKit, (b) one focused issue per tool (read, write, search) so each lands independently.
- `2026-07-13T15:59:52Z`: Implemented WorkspaceTools: a workspace-rooted opt-in tool suite (readFile, writeFile, editFile, listDirectory, searchFiles) gated by PathPolicy. writeFile/editFile set requiresApproval so hosts can gate mutations. Ships as .workspaceTools(root:) and .readOnlyWorkspaceTools(root:) helpers on [any Tool]. Sensible defaults: 512 KiB read cap, 500-entry list cap, 100-hit search cap, prunes hidden/.build/.git/node_modules/DerivedData/etc. 24 new tests.

---

## 80: Built-in web tool

+++
status: open
priority: medium
kind: feature
labels: effort:l, deferred
created: 2026-07-13T15:19:17Z
updated: 2026-07-13T15:29:15Z
+++

CollaborationKit should ship a built-in web tool (fetch/browse URLs, and possibly search) that users can enable and configure on a session.

Must be opt-in: disabled by default. Host apps explicitly enable it and provide configuration.

Scope to define:

---

## 81: Demo app: add more tabs (e.g. canvas sketch view with tools)

+++
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T15:19:26Z
updated: 2026-07-13T16:29:44Z
closed: 2026-07-13T16:29:44Z
+++

The Demo app currently has a limited set of tabs. Add more tabs to showcase additional CollaborationKit capabilities.

One candidate: a canvas sketch view with drawing tools, to demonstrate a richer non-chat surface driven by the same session/tool infrastructure.

Other tab ideas welcome; this issue is a placeholder to expand the demo's coverage.

- `2026-07-13T15:37:58Z`: Reviewed. Punting: the issue is a placeholder with no committed scope. Concrete build-out (e.g. a canvas sketch view with drawing tools driven through session tools) is a meaningful feature in its own right and not effort:m — closer to l/xl. Can you pick a specific tab to prioritize (canvas? a search-and-browse tab? a settings/model-picker showcase?) and file a focused issue for that one, or should this stay as a rolling wishlist?
- `2026-07-13T16:29:44Z`: Added a Sketch tab. DemoSketch exposes setBackground/addLine/addRectangle/addEllipse/addPath/list/undo/delete/clear as collaboration tools. SketchCanvasView provides freehand drawing with a palette. ContentView wraps Notes + Sketch in a TabView and combines both tool sets on the assistant.

---

## 82: Tapping an attachment in the composer/editor field should open a viewer

+++
status: closed
priority: medium
kind: enhancement
labels: effort:s
created: 2026-07-13T15:20:26Z
updated: 2026-07-13T15:35:01Z
closed: 2026-07-13T15:35:01Z
+++

In the composer/editor field, attachments are shown but tapping them does nothing. Tapping an attachment should open it in a viewer, same as attachments elsewhere in the UI.

- `2026-07-13T15:35:01Z`: Tapping a pending composer attachment now opens a popover with the full-size image. Popover chosen over sheet per #83.

---

## 83: Use a popover for attachment viewing

+++
status: closed
priority: medium
kind: enhancement
labels: effort:s
created: 2026-07-13T15:20:26Z
updated: 2026-07-13T15:35:39Z
closed: 2026-07-13T15:35:39Z
+++

Attachment viewing should be presented as a popover (anchored to the attachment) rather than a sheet or separate window.

- `2026-07-13T15:35:39Z`: Transcript attachment viewer switched from sheet to popover anchored on the thumbnail.

---

## 84: Cannot drag or export attachments out of editor/transcript

+++
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T15:21:30Z
updated: 2026-07-13T15:41:46Z
closed: 2026-07-13T15:41:46Z
+++

Attachments in the editor and transcript views can be dropped in, but there is no way to drag them back out or export them to disk. Users need a way to save/extract attachments once they're in the app.

- `2026-07-13T15:41:46Z`: Composer and transcript attachment thumbnails are now draggable (FileRepresentation to a temp file with the correct extension), and each preview popover has a Save… button that opens fileExporter with the right UTType and default filename.

---

## 85: KeepRecentCompactionStrategy triggers on message count, not token usage

+++
status: closed
priority: medium
kind: enhancement
labels: effort:s
created: 2026-07-13T15:30:55Z
updated: 2026-07-13T15:37:31Z
closed: 2026-07-13T15:37:31Z
+++

The built-in `KeepRecentCompactionStrategy` decides whether to compact based on `history.count` vs `minMessagesBeforeCompacting` — a content/message-count heuristic. `TokenUsage` is already threaded through `CompactionStrategy.compact(history:usage:)` but the default strategy ignores it.

Message count is a poor proxy for context-window pressure: a few long tool_result blocks can blow the window while many short turns stay well within it.

Switch the default trigger to be token-based (e.g. compact when cumulative or last-turn tokens exceed a configurable threshold), and keep the message-count knob only as a secondary/floor guard if useful. Related: #78 (surfacing tokens/% until compaction).

- `2026-07-13T15:37:31Z`: Added optional triggerAtTokens to KeepRecentCompactionStrategy. When set, compaction runs on cumulative input tokens; minMessagesBeforeCompacting acts as a floor guard. Legacy message-count behavior preserved when nil.

---

## 86: Investigate apple/foundation-models-utilities for reuse in CollaborationKit

+++
status: open
priority: medium
kind: task
labels: effort:m
created: 2026-07-13T15:46:36Z
updated: 2026-07-13T16:42:21Z
+++

Apple published https://github.com/apple/foundation-models-utilities — a set of utilities for the Foundation Models framework.

CollaborationKit already integrates FoundationModels for on-device inference. It's unknown which of these utilities (if any) overlap with, could replace, or could improve our current code (e.g. streaming helpers, tool-calling glue, schema/JSON adapters, prompt scaffolding, session/context management, testing helpers).

Tasks:
- Audit the repo's public API surface and license.
- Compare against our current FoundationModels usage in CollaborationKit.
- Identify concrete adoption opportunities (what to delete, what to wrap, what to depend on).
- Decide: vendor, depend as SPM package, or copy patterns.

---

## 87: CollaborationKitUI: transcript-row customization hooks (per-tool icon, per-tool result filter)

+++
status: closed
priority: medium
kind: enhancement
labels: effort:m, phosphor-adoption
created: 2026-07-13T15:49:46Z
updated: 2026-07-13T17:07:10Z
closed: 2026-07-13T17:07:10Z
+++

For Phosphor to drop its hand-rolled ConversationRow, CollaborationKitUI's transcript row needs host-supplied hooks for per-tool presentation.

Phosphor's ConversationRow varies by tool name:

- Icon: 'read'→doc.text, 'edit'→pencil, 'writeConfiguration'→slider.horizontal.3, 'compileShader'→hammer, default 'wrench.and.screwdriver'.
- resultWorthShowing predicate: hide the body for 'Edit applied.' / 'Compiles cleanly.' noise, but always show it for errors and for 'readConfiguration'/'read'/'compileShader' failures.

CollaborationKitUI's summarizeTool closure already covers the argument summary (per row). We need two more hooks, likely as ConversationStore init params or environment values:

- toolIcon: @Sendable (ToolUse) -> String (SF Symbol name), with a sensible built-in for read/write/edit.
- shouldShowToolResult: @Sendable (ToolUse, result: String, isError: Bool) -> Bool.

Design decisions:
- Env values (per-view override) vs. ConversationStore init params (per-store)?
- Should hosts get the whole ToolUse or just the name?

Blocker for the Phosphor migration umbrella.

- `2026-07-13T17:07:10Z`: Resolved by change rlomzonm ('Fix #87: transcript-row result-visibility hook'). ToolPresenterRegistry now exposes resultVisibility(_:) for the lightweight per-tool result predicate. Per-tool icons (iconForTool) and full-body overrides (ToolPresenterRegistry.presenter(for:view:)) were already in place.

---

## 88: CollaborationKitUI: empty-state customization slot for the transcript

+++
status: closed
priority: medium
kind: enhancement
labels: effort:s, phosphor-adoption
created: 2026-07-13T15:49:59Z
updated: 2026-07-13T17:04:24Z
closed: 2026-07-13T17:04:24Z
+++

For Phosphor to drop its hand-rolled GeneratePanel, CollaborationKitUI's transcript needs a host-supplied empty state.

Phosphor shows two distinct ContentUnavailableView states today:

- No conversation yet: 'Generate a Shader' with a shader-specific hint.
- Missing credentials: 'Sign in to Generate' with a SettingsLink.

Design options:

- A single .emptyState { … } modifier on CollaborationChatView that takes a @ViewBuilder.
- Separate slots for 'empty transcript' vs 'not ready to send' (credentials missing, provider not configured).
- A default built-in view that hosts can accept if they want a generic experience.

Related: composer-status slot (companion issue) and #37 (menu-command hooks).

Child of the Phosphor adoption umbrella.

- `2026-07-13T17:04:24Z`: Empty-state slot shipped in change tzmvomtkzrsy (fix for #65): TranscriptView and CollaborationChatView both expose an emptyPlaceholder ViewBuilder init. Follow-up for the separate credentials-missing slot filed as its own issue.

---

## 89: CollaborationKitUI: composer status/model-info slot above the prompt field

+++
status: closed
priority: medium
kind: enhancement
labels: effort:s, phosphor-adoption
created: 2026-07-13T15:50:08Z
updated: 2026-07-13T17:04:18Z
closed: 2026-07-13T17:04:18Z
+++

For Phosphor to drop its hand-rolled composer, CollaborationKitUI's composer needs a host-supplied status strip above the prompt field.

Phosphor shows a small caption line above the prompt today:

    cpu  Claude · claude-3-5-sonnet-20241022

That combines: the backend name, the selected model id, and (implicitly) an affordance to change it. It's small, taste-sensitive, and provider-specific — so it doesn't belong in CollaborationKitUI's default composer.

Proposal: expose a slot (@ViewBuilder) on ComposerView / CollaborationChatView that hosts render into the caption row above the prompt. Something like:

    CollaborationChatView(store: store) {
        // transcript body slot?
    } composerAccessory: {
        BackendChip(backend: backend)
    }

Consider whether this should be one slot or a small set (leading caption / trailing caption / above-prompt / below-prompt).

Related: transcript-row hooks and empty-state slot (companion issues).

Child of the Phosphor adoption umbrella.

- `2026-07-13T17:04:18Z`: Already shipped in change unuxlslntlmx ('ComposerView: add optional header slot for backend/model caption'). ComposerView has a @ViewBuilder header slot and CollaborationChatView exposes composerHeader: on its init; matches the proposal in this issue exactly.

---

## 90: Public API surface audit for Phosphor adoption

+++
status: closed
priority: medium
kind: task
labels: effort:m, phosphor-adoption, api
created: 2026-07-13T15:50:17Z
updated: 2026-07-13T17:09:45Z
closed: 2026-07-13T17:09:45Z
+++

Before Phosphor migrates off its hand-rolled UI/store onto CollaborationKit + CollaborationKitUI, inventory the surface it will consume and make sure everything is public, documented, and stable.

Inputs:

- Walk Phosphor's Support/ConversationStore.swift, Views/GeneratePanel.swift, Views/ExportDebugLogCommand.swift, Support/ConversationExport.swift, and Packages/PhosphorSupport/Sources/PhosphorGeneration/Collaboration/*.
- For every CollaborationKit / CollaborationKitUI type, method, or property that a replacement version of GeneratePanel would need, confirm it is 'public' with a doc comment.

Deliverable:

- A checklist (one line per symbol) of what's already public/documented vs. what needs to be promoted.
- A follow-up issue per gap (or a single 'promote to public' PR if the gap is small).
- A short note on any API shapes that look right today but would be painful for Phosphor to consume (e.g. missing @Sendable, missing default arguments, missing environment plumbing).

Related to the other Phosphor-adoption children — resolving those may add new surface that this audit needs to cover.

Child of the Phosphor adoption umbrella.

- `2026-07-13T17:09:45Z`: Audit written up in rfcs/phosphor-adoption-audit.md (change kxvlonqm). Follow-ups filed:

- #103 — CollaborationChatView missing-credentials placeholder is hard-coded.
- #104 — ConversationStore has no rehydrate-from-SessionExport path (child of #73).

The rest of the phosphor-adoption umbrella children (#37, #27, #73, #74, #78) are the right home for their gaps; #87/#88/#89 already shipped.

---

## 91: Prepare for Phosphor Adoption

+++
status: open
priority: high
kind: task
labels: epic, phosphor-adoption, effort:xl
depends: 37, 27, 73, 74, 78, 87, 88, 89, 90, 103, 104
created: 2026-07-13T15:50:39Z
updated: 2026-07-13T17:09:59Z
+++

Umbrella tracking the work needed so Phosphor can retire its hand-rolled GeneratePanel / ConversationStore / ExportDebugLogCommand and consume CollaborationKit + CollaborationKitUI directly.

Phosphor today owns a parallel implementation of most of what CollaborationKitUI ships:

- A domain ConversationStore with rollback snapshots, prompt queue, streaming overlay, error overlays, tool timing, and its own transcript projection.
- A GeneratePanel with a full transcript + composer, empty states, missing-credentials view, model-info chip, attachment strip, and File-menu export wiring.
- A private ExportDebugLogAction + FocusedValues.exportDebugLog for the File menu.

Most of that has since landed in CollaborationKitUI (ConversationStore, MessageMirror, ExportDebugLogAction, SessionDebugExportModifier, rollback, prompt queue). The remaining gaps are the reason this umbrella exists.

## Children

Existing:

- #37 — CollaborationKitUI: menu-command / focused-scene-value hooks. Phosphor needs a File-menu 'Stop Generation' and 'Roll Back to Previous Turn' in addition to the already-wired exportDebugLog. #26 has landed, so the rollback dependency is no longer a blocker.
- #27 — CollaborationKitUI: Theme type with environment plumbing. Phosphor renders the chat in an inspector panel and needs it to blend with the shader UI.
- #73 — Persist conversations across launches. Phosphor is document-based; sessions must survive open/close.
- #74 — Dragging an image onto the composer text field pastes the file path as text. Bug Phosphor hits today; blocks credible drag-and-drop UX in the migrated composer.
- #78 — Show tokens/% remaining until compaction. Phosphor already surfaces a raw token count; upgrade path.

New:

- #87 — Transcript-row customization hooks (per-tool icon, per-tool result-worth-showing predicate).
- #88 — Empty-state customization slot for the transcript.
- #89 — Composer status/model-info slot above the prompt field.
- #90 — Public API surface audit for Phosphor adoption.

## Definition of done

- Every child resolved (fixed, or explicitly wontfixed after confirming Phosphor doesn't need it).
- Phosphor has an experimental branch replacing GeneratePanel with CollaborationChatView (or the equivalent umbrella view) and none of the local hand-rolled types.
- No behavioral regressions vs. today's GeneratePanel (streaming, rollback, export, attachments, tokens).

## Non-goals

- Phosphor's shader-domain plumbing (ShaderTools, MetalSourceDocument, PhosphorConfigurationSchema) stays in Phosphor.
- Phosphor's own FocusedValueKey values for shader-domain state (shaderText, shaderTextMutator) stay in Phosphor.

## Notes

- The bulk of the migration is UI-facing; the Core-side APIs Phosphor uses (Message, ImageContent, LLMSession, ToolSpec, ProviderStreamEvent, TokenUsage, RollbackSnapshot) are already stable enough. #90 will confirm.

- `2026-07-13T17:09:59Z`: Progress update (change kxvlonqm):

Phosphor-labeled children resolved:
- #87 ✅ transcript-row result-visibility hook
- #88 ✅ empty-state slot (shipped earlier as #65)
- #89 ✅ composer header slot (shipped earlier)
- #90 ✅ public-API audit — see rfcs/phosphor-adoption-audit.md

New follow-ups added to this umbrella:
- #103 — CollaborationChatView missing-credentials placeholder is hard-coded.
- #104 — ConversationStore rehydration path (blocks the persistence child #73).

Still open on the umbrella (from the original dependency list):
- #37 menu-command / focused-scene hooks
- #27 Theme type
- #73 persistence
- #74 image-drop-as-text bug
- #78 tokens/% until compaction

None of these are phosphor-adoption-labeled today; they're deferred separately.

---

## 92: Compaction strategies must count tokens, never messages

+++
status: closed
priority: high
kind: enhancement
labels: effort:s, architecture
created: 2026-07-13T15:51:25Z
updated: 2026-07-13T16:29:55Z
closed: 2026-07-13T16:29:55Z
+++

Compaction decisions must be driven by token counts reported by the backend (or, in future, a caller-supplied estimator), never by message count. The backend is the only source of truth for context-window pressure — message count is a poor proxy that hides long tool_result blocks and over-triggers on chatty short turns.

Follow-ups (existing callers may break; no external consumers yet):

- Remove `minMessagesBeforeCompacting` from `KeepRecentCompactionStrategy`. Both its roles today (legacy trigger when `triggerAtTokens` is nil, and floor-guard when set) are message-count logic.
- Make `triggerAtTokens` a required init parameter.
- Rewrite tests that pass `minMessagesBeforeCompacting: 0` to set `triggerAtTokens` instead.
- Any new `CompactionStrategy` conformance must derive its trigger from `usage.inputTokens` (provider-reported cumulative input tokens) or an equivalent token-count source. Message count is off the table.

Blocks: #78 (tokens/% until compaction — meaningless without a token-based trigger).
Follows: #85 (added `triggerAtTokens`; this issue completes the transition).

- `2026-07-13T16:29:55Z`: Landed together: KeepRecentCompactionStrategy is now token-triggered only (triggerAtTokens required, minMessagesBeforeCompacting removed), and CompactionStrategy gains a compactionProgress(usage:) hook that KeepRecent implements. ConversationStore surfaces it as compactionProgress; ComposerView renders a 'used / limit' chip that hides itself when the strategy has no budget.

---

## 93: Support pi as a chat backend/mode

+++
status: open
priority: medium
kind: feature
labels: deferred, effort:xl
created: 2026-07-13T16:38:44Z
updated: 2026-07-13T16:44:45Z
+++

Add a new chat backend alongside the existing remote providers (Anthropic, OpenAI) that talks to a locally running `pi` model over a Unix domain socket.

macOS only.

Distinct enough from the remote HTTP providers that it likely warrants its own backend type and settings surface (socket path, model selection, etc.) rather than shoehorning into the existing HTTP-based provider abstraction.

---

## 94: Support slash commands in the composer

+++
status: open
priority: medium
kind: feature
labels: effort:m, deferred
created: 2026-07-13T16:38:45Z
updated: 2026-07-13T16:44:00Z
+++

Let the user type slash commands (e.g. `/clear`, `/model …`, `/export`) in the composer to trigger app or session actions without a tool round-trip.

Needs:
- A registry of available commands with descriptions.
- Composer UI: autocomplete/menu when the prompt starts with `/`.
- Dispatch that runs the command instead of sending the text to the model.

---

## 95: Send a notification when a conversation turn finishes

+++
status: open
priority: medium
kind: feature
labels: effort:s
created: 2026-07-13T16:39:20Z
updated: 2026-07-13T16:42:21Z
+++

When the assistant finishes a turn (or errors), post a user notification so the user can leave the window in the background and come back when work is done.

Should probably only fire when the app/window is unfocused.

---

## 96: Support local LLM servers (LM Studio, Ollama, etc.)

+++
status: closed
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T16:39:46Z
updated: 2026-07-13T17:10:10Z
closed: 2026-07-13T17:10:10Z
+++

Support talking to local LLM servers that expose HTTP APIs — e.g. LM Studio, Ollama, llama.cpp server, vLLM.

Most of these speak an OpenAI-compatible `/v1/chat/completions` dialect, so this may just need a configurable base URL + auth (optional API key) reusing the existing OpenAI provider, plus UI in Settings to add/manage local endpoints.

Distinct from #93 (which is native `pi` over a Unix socket) — this issue covers HTTP-speaking local servers.

---

## 97: Support extended thinking / reasoning content

+++
status: open
priority: medium
kind: feature
labels: effort:l, deferred
created: 2026-07-13T16:40:20Z
updated: 2026-07-13T16:44:00Z
+++

Handle models that emit thinking / reasoning content separately from the assistant response — Anthropic extended thinking, OpenAI o-series reasoning tokens, etc.

Needs:
- Request-side: opt in to thinking (per-model or per-turn), with a budget where the API supports one.
- Wire: parse and preserve thinking blocks from the stream (including signed/redacted variants for Anthropic).
- History: keep thinking blocks on the assistant message so multi-turn tool use round-trips them back correctly.
- UI: render as a collapsible/dimmed block distinct from the main answer.

---

## 98: Support some form of tool batching

+++
status: open
priority: medium
kind: feature
labels: effort:l
created: 2026-07-13T16:40:46Z
updated: 2026-07-13T16:42:21Z
+++

Right now every tool call is its own round-trip: model emits one `tool_use`, we run it, send back one `tool_result`, repeat. For tasks with lots of small independent calls (list + read a dozen files, fetch several notes, etc.) this is slow and burns tokens on repeated context.

Want _some_ way to batch:
- Run multiple `tool_use` blocks from a single assistant turn in parallel and return all `tool_result`s in one user message (Anthropic already supports this shape natively).
- Or expose a meta/batch tool the model can call with a list of sub-calls.
- Or let a tool declare it accepts array input and fan out internally.

Exact design is open — the goal is fewer round-trips for embarrassingly-parallel tool work.

---

## 99: Tool rows sometimes don't show a duration

+++
status: new
priority: medium
kind: bug
labels: effort:s, needs-info
created: 2026-07-13T16:41:24Z
updated: 2026-07-13T16:42:21Z
+++

The transcript should show how long each tool call took (the duration label in the row header), but it is missing on some tool rows.

Not yet clear which tools or which conditions trigger it — could be tools that finish before a duration can be stamped, tools whose result arrives outside the mirrored event stream, or history-replay rows that never saw the live `.toolResult` event.

Repro guidance for later investigation: run a session with several tool calls, look for rows where the header has no `Xs`/`Xms` label on the right.

---

## 100: MCP Support

+++
status: open
priority: medium
kind: task
labels: deferred, effort:xl
created: 2026-07-13T16:43:43Z
updated: 2026-07-13T16:44:30Z
+++

---

## 101: Composer: up/down arrow to recall previous prompts

+++
status: open
priority: medium
kind: feature
labels: effort:s
created: 2026-07-13T16:52:37Z
updated: 2026-07-13T17:37:13Z
+++

Let the user press up/down in the composer to cycle through their previously-submitted prompts (shell/REPL style), so they can re-run or edit a past prompt without retyping.

Behavior questions to resolve during implementation:
- History scope: per session, per store, or persisted across launches?
- Up on a non-empty prompt: replace, or only trigger on empty?
- Do we snapshot the in-progress prompt so down-arrow can return to it?

---

## 102: Transcript doesn't auto-scroll to the bottom

+++
status: open
priority: medium
kind: bug
labels: effort:s
created: 2026-07-13T16:56:32Z
updated: 2026-07-13T17:37:13Z
+++

The transcript is supposed to keep the newest content in view as messages/tool calls stream in, but it stops scrolling to the bottom.

Details to nail down:
- Does it happen from the start of a session, or only after some interaction (e.g. the user scrolls up once)?
- Streaming assistant text vs. new user message vs. tool result — does it break for all of them or just some?
- Which platform (macOS window resize? iOS keyboard?).

---

## 103: New demo: collaborative document editor

+++
status: closed
priority: medium
kind: feature
created: 2026-07-13T17:06:26Z
updated: 2026-07-13T17:13:15Z
closed: 2026-07-13T17:13:15Z
+++

A third demo alongside Notes and Sketch: one big text editor that the user and the assistant edit together.

Shape:
- The whole window is a single text document the user can freely edit.
- The chat inspector is available as usual; the assistant can make edits to the document via tools (insert, replace ranges, etc.).
- When the assistant edits, the demo should visually surface where the changes are — options to explore:
  - Inline highlight of changed spans (fades out over a few seconds).
  - Dots/markers in the gutter next to changed lines.
  - Auto-scroll to the first edit of the batch.
- Optional stretch: an "accept/reject" affordance per edit before it lands.

Purpose: show off tool-driven document editing and the store/mirror handling a fast stream of small mutations to a large body of text.

---

## 104: ConversationStore: rehydrate from a persisted SessionExport / MessageMirror

+++
status: open
priority: medium
kind: feature
labels: phosphor-adoption, api, effort:m
depends: 73
created: 2026-07-13T17:09:09Z
updated: 2026-07-13T17:37:13Z
+++

`ConversationStore.buildExport(model:userInfo:)` produces a `SessionExport` today, but there is no corresponding initializer or method that restores a store from one. A host that persists a conversation across launches (see #73) has no way to bring a store back into the same state it left.

Two related shapes are also non-`Codable` at present:

- `MessageMirror` is `Sendable` but not `Codable`. Its `messages` array is public, but the streaming overlay, error overlays, and per-item presentation metadata (timestamps, durations, summaries) are not persistable.
- `ConversationItem` is `Codable` and can be serialized via the projection, but there's no way to feed a saved array back into a mirror.

Impact:

- Blocks Phosphor adoption on the persistence axis of the #91 umbrella. Phosphor is document-based and wants sessions to survive open/close.
- Any host addressing #73 will hit this the moment they try to reopen a saved document.

Surfaced by the #90 public-API audit for Phosphor adoption. Child of #73.

---

## 105: CollaborationChatView: missing-credentials placeholder is not host-customizable

+++
status: open
priority: medium
kind: enhancement
labels: phosphor-adoption, effort:s
depends: 91
created: 2026-07-13T17:04:35Z
updated: 2026-07-13T17:37:13Z
+++

CollaborationChatView shows a hard-coded ContentUnavailableView ("Sign in to Continue" + SettingsLink) when the ambient CollaborationCredentials reports no stored credentials for the current backend.

Hosts have no way to replace or customize this view. Phosphor, for example, wants "Sign in to Generate" with a shader-specific hint. #88 added an emptyPlaceholder slot for the empty-transcript case; the credentials-missing case is a separate, still-uncustomizable state.

Companion to #88 (which shipped only the empty-transcript slot). Child of the #91 Phosphor adoption umbrella.

---

## 106: Parallel tool dispatch within a single assistant turn

+++
status: open
priority: low
kind: feature
labels: effort:m
depends: 98
created: 2026-07-13T17:14:35Z
updated: 2026-07-13T17:37:13Z
+++

Follow-up to #98. Today LLMSession.runPendingTools runs each pending tool serially, in the order the model emitted them. The wire already batches results (one user message with N tool_result blocks), so #98's round-trip/token win is covered — this is purely about wall-clock inside our loop when the model emits multiple independent I/O-bound calls in the same turn.

Would like to fan the batch out via a task group so N HTTP fetches / file reads / etc. can overlap instead of adding up.

Sharp edges to design around:

- Approval flow: the host's approval closure is currently awaited serially. Parallel dispatch must keep prompts serialized in emitted order so interactive UIs don't pop N dialogs at once.
- Tool safety: tool authors need a way to say "don't run me concurrently with siblings" for tools with shared side effects (writing the same file, hitting a rate-limited endpoint, mutating a shared store). Design options considered so far:
  - Per-tool bool (allowsParallelExecution) — coarse but easy.
  - Exclusion keys (exclusionKey: String?) — tools sharing a key serialize; expresses cross-tool exclusion too.
  - Session-level kill switch — one bool on LLMSession; simplest, no per-tool surface.
  - Do nothing; expect tools to guard their own state with actors/locks.
- Event ordering: .toolResult events would fire in completion order, not request order. Consumers should already key by ToolUse.id (attachResult does), but any that rely on emission order break.
- Provider defaults: Anthropic parallel tool use is on by default (opt-out disable_parallel_tool_use); OpenAI has parallelToolCalls already wired. Nothing new needed on the wire.

Deferred from the initial #98 pass because parallel-by-default was judged too dangerous for tools whose safety story we don't own.

---

## 107: Approval prompt has no "always allow this tool" option

+++
status: open
priority: medium
kind: feature
labels: effort:s
created: 2026-07-13T17:22:00Z
updated: 2026-07-13T17:37:17Z
+++

When a tool marked `requiresApproval: true` runs, the user gets an Allow/Deny prompt for every invocation. There is no way to whitelist a tool for the rest of the conversation (or session), so repeated calls to the same tool require repeated clicks.

- `2026-07-13T17:37:17Z`: Related: #108 (approval confirm UI styling).

---

## 108: Tool-approval confirm UI is ugly

+++
status: open
priority: low
kind: enhancement
labels: ui, demo, effort:s
created: 2026-07-13T17:32:04Z
updated: 2026-07-13T17:37:17Z
+++

The tool-call approval dialog in the CollaborationDemo (SwiftUI `.alert` driven by `ApprovalGate`, wired up in `ContentView.swift` around line 90) looks bad.

Observed problems (see `Documentation/Screenshots/approval-alert-ugly.png`):
- Body is a raw JSON dump of the tool input, escaped (`\"`, `\n`) rather than pretty-printed or rendered.
- Long string arguments wrap awkwardly and dominate the dialog.
- No visual separation between the tool name (`rewrite`) and its arguments.
- Three stacked pill buttons (Allow / Deny / Cancel) with Deny highlighted in red look heavy and unbalanced; unclear why Deny and Cancel are both present.
- Overall styling is default `.alert` chrome — no typography hierarchy, no monospaced/code styling for the payload, no truncation for large inputs.

Investigate a better presentation for the approval confirm UI (tool name + human-readable summary of arguments, proper code formatting for the payload, clearer Allow/Deny affordances).

- `2026-07-13T17:37:17Z`: Related: #107 ("always allow this tool" option).

---

## 109: Queued prompts aren't shown in the transcript and can't be cancelled individually

+++
status: open
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T17:33:35Z
updated: 2026-07-13T17:37:13Z
+++

When the user submits a prompt while a turn is running, `ConversationStore` queues it (`pendingPromptCount` reflects this) but the transcript doesn't render the queued prompts. There's no per-prompt affordance to cancel a single queued prompt before it sends — only `clearPendingPrompts()`, which drops the whole queue.

## Proposed fix (per user)
Render queued prompts inline in the transcript with a cancel (×) button on each row.

---

## 110: Verify prompt caching is enabled and effective across all providers

+++
status: open
priority: medium
kind: task
labels: effort:s
created: 2026-07-13T17:35:12Z
updated: 2026-07-13T17:37:13Z
+++

Anthropic has `promptCaching: Bool = true` and inserts `cache_control` breakpoints on the stable request prefix. OpenAI has no explicit prompt-caching handling — it relies on server-side automatic caching, with no client-side verification that it's actually engaging (or surfacing the resulting hit/miss stats). No coverage or docs for future providers.

Audit whether prompt caching is actually working end-to-end for each supported provider, and document the stance.

---

## 111: Clarify default behavior for parallel/batch tool calls across providers

+++
status: open
priority: medium
kind: task
labels: effort:xs
created: 2026-07-13T17:35:12Z
updated: 2026-07-13T17:37:13Z
+++

OpenAI exposes `parallelToolCalls: Bool?` (nil = provider default, which is enabled). Anthropic has no equivalent knob, so we implicitly accept the API default (parallel tool use enabled). There's no shared, documented stance on whether CollaborationKit opts in to parallel/batch tool dispatch, and no cross-provider way to disable it. Related to #106 (parallel tool dispatch within a single assistant turn).

---

## 112: Demo doesn't showcase batched / parallel tool usage

+++
status: open
priority: medium
kind: feature
labels: effort:s
created: 2026-07-13T17:35:49Z
updated: 2026-07-13T17:37:14Z
+++

When the model emits multiple tool calls in one assistant turn, the demo tabs (notes, sketch, doc) render them as a plain sequence of tool rows. There's no visual indication that they were dispatched as a batch, and no example workflow in the demo that exercises batching to make the behavior visible.

Related: #106 (parallel tool dispatch), #111 (opt-in defaults).

---

## 113: SessionExport.system field is always nil — no way to include the session's system prompt in a debug export

+++
status: closed
priority: medium
kind: bug
labels: effort:s
created: 2026-07-13T17:45:10Z
updated: 2026-07-13T17:53:31Z
closed: 2026-07-13T17:53:31Z
+++

`SessionExport` declares a `public var system: String?` field (intended to hold the system prompt used for the session, so exported debug bundles record *what the model was told* alongside the transcript). The initializer takes it as a parameter.

But `ConversationStore.buildExport(model:userInfo:)` hard-codes `system: nil`, and `LLMSession.system` is `private let` with no public accessor. So there is no supported way for a host to populate the field — it is effectively dead.

## Impact

Debug exports are missing the single most important piece of context for reproducing model behavior: the instructions that produced it. Hosts like Phosphor have to keep their own parallel export type (with an `instructions` field) to work around this.

## Repro

```swift
let session = LLMSession(provider: p, system: "You are a helpful assistant.", tools: [])
let store = ConversationStore(session: session)
let export = store.buildExport()
print(export.system) // nil, always
```

## Options (per user, not prescriptive)

- `2026-07-13T17:45:10Z`: Expose `LLMSession.system` as `public var` (or `public var systemPrompt: String? { get }`) and have `buildExport` read it.
- `2026-07-13T17:45:10Z`: Or accept `system:` as a parameter on `buildExport(model:system:userInfo:)`.
- `2026-07-13T17:45:10Z`: Or drop the field entirely if it is intentionally not tracked.
- `2026-07-13T17:53:31Z`: Fixed in dc20fb18.

---

## 114: Backend.openAI has no way to disable parallel tool calls without rebuilding the whole Backend value

+++
status: closed
priority: low
kind: enhancement
labels: effort:s
created: 2026-07-13T17:45:21Z
updated: 2026-07-13T17:53:31Z
closed: 2026-07-13T17:53:31Z
+++

`OpenAIConfig` supports `parallelToolCalls: Bool?` (defaulting to `nil` → server default, which is `true`). But the built-in `Backend.openAI` static value constructs its `OpenAIConfig` inline and never passes the flag through, so there's no way for a host to opt out of parallel tool calls while still using the built-in backend.

Hosts building agentic loops (read → edit → compile, plan → act → verify, etc.) generally need sequential tool calls: a parallel model may issue a blind edit alongside a config write before it has seen the current state. The only workaround today is to copy the entire `Backend.openAI` value literal into the host and flip the one flag — a lot of surface area to duplicate for one line of config, and it drifts as CK updates the built-in.

## Impact

Any host wiring `Backend.openAI` into an agentic loop has to either accept parallel tool calls (potentially incorrect for its workflow) or fork the built-in backend.

## Options (per user, not prescriptive)

- `2026-07-13T17:45:21Z`: Add a `Backend.openAI(parallelToolCalls: Bool? = nil)` factory alongside the existing static value.
- `2026-07-13T17:45:21Z`: Expose an `OpenAIConfig` customization hook on the built-in backends (a `configure: (inout OpenAIConfig) -> Void` closure passed through `makeProvider`).
- `2026-07-13T17:45:21Z`: Or document the recommended fork pattern so hosts know what they're signing up for.
- `2026-07-13T17:53:31Z`: Fixed in dc20fb18.

---

## 115: No UI to configure LM Studio (or other local LLM servers)

+++
status: new
priority: medium
kind: enhancement
created: 2026-07-13T17:57:29Z
+++

Settings has no way to point CollaborationKit at a local LM Studio server. The provider picker only shows the hosted backends (Claude Subscription, Anthropic API, OpenAI); LM Studio isn't offered, so there's no place to enter the base URL or pick a local model from the UI.

Same story for other local OpenAI-compatible servers (Ollama).

---
