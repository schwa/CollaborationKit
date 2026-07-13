# Phosphor Adoption — Public API Audit

- **Status:** Snapshot (2026-07-13)
- **Author:** @schwa
- **Tracking:** [#90](../ISSUES.md), umbrella [#91](../ISSUES.md)

This is a one-time inventory of the CollaborationKit + CollaborationKitUI public
surface against what Phosphor needs to retire its hand-rolled `GeneratePanel`,
`ConversationStore`, and `ExportDebugLogAction`. See #91 for the umbrella and
the Phosphor-side motivation.

Symbols marked ✅ are public with a doc comment. Symbols marked ⚠️ are public
but have a note. Symbols marked ❌ are missing or unreachable from Phosphor.

## Store surface

Everything Phosphor's own `ConversationStore` exposes has a counterpart in
`CollaborationKitUI.ConversationStore`.

| Phosphor need                 | CollaborationKit(UI) symbol                                                                          | Status |
| ----------------------------- | ---------------------------------------------------------------------------------------------------- | ------ |
| Rollback snapshots            | `RollbackSnapshot`, `ConversationStore.send(_:images:snapshot:)`, `.canRollBack(to:)`, `.rollBack(through:)` | ✅     |
| Prompt queue                  | `ConversationStore.pendingPromptCount`, `.clearPendingPrompts()`                                     | ✅     |
| Streaming overlay             | `MessageMirror.streamingAssistantText`                                                               | ✅     |
| Error overlays                | `MessageMirror.errorOverlays`, `ConversationStore.lastError`                                         | ✅     |
| Tool timing                   | `MessageMirror.Presentation.duration`, `ConversationItem.duration`/`.latency`                        | ✅     |
| Transcript projection         | `TranscriptProjection.project(_:)`, `ConversationStore.items`                                        | ✅     |
| Token usage                   | `ConversationStore.usage`, `TokenUsage`                                                              | ✅     |
| Compaction progress chip      | `ConversationStore.compactionProgress`, `CompactionProgress`, `CompactionStrategy`                   | ✅     |
| Stop turn                     | `ConversationStore.stop()`, `.isGenerating`                                                          | ✅     |
| Rebuild raw history           | `ConversationStore.messages`, `MessageMirror.messages`                                               | ✅     |
| Rehydrate from persisted state| Initializer that takes a saved `MessageMirror` / `SessionExport`                                     | ❌     |

The rehydration gap is not on the umbrella yet as its own child — it's implied
by #73 (persistence) but hasn't been called out separately. Filed as a
follow-up (see below).

## Chat view surface

| Phosphor need                                | Symbol                                                       | Status |
| -------------------------------------------- | ------------------------------------------------------------ | ------ |
| Transcript + composer container              | `CollaborationChatView`                                      | ✅     |
| Custom empty-transcript placeholder          | `CollaborationChatView(store:…​ emptyPlaceholder:)`          | ✅     |
| Custom composer header (backend/model chip)  | `CollaborationChatView(store:…​ composerHeader:)`            | ✅     |
| Custom missing-credentials placeholder       | Currently hard-coded in `CollaborationChatView.missingCredentials` | ❌ (#103) |
| Border style (plain / glow)                  | `ComposerBorderStyle`                                        | ✅     |
| Per-tool icon lookup                         | `CollaborationChatView(iconForTool:)`, `ConversationRowView.defaultIcon(for:)` | ✅ |
| Per-tool result visibility                   | `ToolPresenterRegistry.resultVisibility(_:)`                 | ✅ (#87) |
| Full per-tool row override                   | `ToolPresenterRegistry.presenter(for:view:)`                 | ✅     |
| Attachment strip / paste / drop              | `ComposerView`, `ComposerAttachmentBuffer` (env), `TranscriptView(onDropURLs:)` | ✅ |
| Transcript row samples                       | `ConversationRowView`, `ConversationItem`                    | ✅     |

## Menu / focused-scene surface

| Phosphor need                                | Symbol                                                       | Status |
| -------------------------------------------- | ------------------------------------------------------------ | ------ |
| Session debug-log export                     | `ExportDebugLogAction`, `FocusedValues.exportDebugLog`, `.sessionDebugExport(store:…​)`, `SessionExport`, `SessionDebugExportModifier` | ✅ |
| `File → Stop Generation` focused-scene value | `FocusedValues.stopGeneration` (or equivalent)               | ❌ (#37) |
| `File → Roll Back to Previous Turn` focused-scene value | `FocusedValues.rollBackLastTurn` (or equivalent)   | ❌ (#37) |

Phosphor can already call `ConversationStore.stop()` and `.rollBack(through:)`
directly, but it wants those wired into the File menu the same way
`exportDebugLog` is. See #37.

## Model / credential surface

| Phosphor need                    | Symbol                                                                                 | Status |
| -------------------------------- | -------------------------------------------------------------------------------------- | ------ |
| Providers                        | `ModelProvider`, `WireProvider`, `AnthropicProvider`, `OpenAIProvider`                 | ✅     |
| Provider configs                 | `AnthropicConfig`, `OpenAIConfig`, error enums                                         | ✅     |
| OAuth (Anthropic)                | `AnthropicOAuth`, `OAuthCredentials`, `OAuthError`, `AnthropicOAuthSection`            | ✅     |
| Credential store abstraction     | `CredentialStore`, `KeychainCredentialStore`, `InMemoryCredentialStore`, `CredentialStoreKey` | ✅ |
| Session-scoped credential holder | `CollaborationCredentials`                                                             | ✅     |
| Settings UI blocks               | `CollaborationSettingsView`, `AnthropicAPIKeySection`, `OpenAIAPIKeySection`, `ModelPickerSection`, `APIKeySection` | ✅ |
| Tool schemas                     | `ToolSpec`, `Tool`, `ToolError`, `ToolUse`, `ToolResult`, `ToolCall`, `ToolApprovalDecision`, `Message`, `Role`, `ContentBlock`, `ImageContent`, `JSONValue` | ✅ |
| Retry / streaming plumbing       | `RetryPolicy`, `StreamingTransport`, `ServerSentEventSink`, `ProviderStreamEvent`, `SessionEvent` | ✅ |
| File tools                       | `FileTools`, `WorkspaceTools`, `FileDocument`, `InMemoryDocument`, `PathPolicy`, `TextDocument` | ✅ |
| Macros                           | `CollaborationSchemaConvertible`, `CollaborationRawValue`, `CollaborationResultConvertible`, `CollaborationResultError` | ✅ |
| Backend catalog                  | `Backend`, `CollaborationCredentialsError`                                             | ✅     |

## Shape concerns worth flagging

Nothing blocking, but worth noting for the migration:

- `CollaborationChatView` has four initializers already, one per combination
  of `emptyPlaceholder?` × `composerHeader?`. Adding the missing-credentials
  slot (#103) doubles that to eight, at which point the ergonomic answer is
  probably to move these slots onto view modifiers or environment values
  (matching the `ToolPresenterRegistry` pattern used for tool-row hooks).
- `MessageMirror` is `Sendable` but not `Codable`. `ConversationItem` is
  `Codable`. To persist a session (#73) hosts have to either serialize `messages`
  (raw history, no presentation metadata) or `items` (projected rows, no way to
  resume a turn). Both work, both lose something. Rehydration API is the real
  fix — see follow-up.
- `ConversationStore.buildExport(model:userInfo:)` is convenient; there is no
  matching `restore(from: SessionExport)`. This is the rehydration gap.
- `iconForTool` is an init param on `TranscriptView`, `ConversationRowView`,
  and `CollaborationChatView`; `ToolPresenterRegistry` is an environment
  injection. Two patterns for the same "customize how rows look" surface.
  Not a bug, but a candidate for consolidation if #103 forces the init
  refactor anyway.

## Follow-ups filed

- #103 — Custom missing-credentials placeholder slot.
- #104 — Rehydrate a `ConversationStore` from a persisted export / mirror
  (blocker for #73; not previously called out).

## Everything else

The rest of the phosphor-adoption umbrella children (#37, #27, #73, #74, #78)
already exist and are the right home for their gaps. No new issues needed for
them.
