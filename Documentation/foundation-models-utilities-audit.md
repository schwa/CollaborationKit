# Audit: `apple/foundation-models-utilities`

Investigation for issue #86. Repo audited at `main`, pushed 2026-07-16.

## What the package is

Apache-2.0, `swift-tools-version: 6.2`, platform floor **macOS 27 / iOS 27 /
visionOS 27 / watchOS 27**. One product, `FoundationModelsUtilities`, built
entirely on top of `FoundationModels` types (`LanguageModelSession`,
`DynamicProfile`, `Transcript`, `Instructions`, `PromptBuilder`).

Three feature areas:

| Area | Files | What it does |
|---|---|---|
| History management | `History/*` | `DynamicProfile` modifiers that trim a transcript: `droppingCompletedToolCalls()`, `rollingWindow(entries:)`, `summarizeHistory(entryThreshold:model:)` |
| Skills | `Skills/*` | `Skills` (a `DynamicInstructions` result builder) + `Skill` + `SkillActivations`. The model activates a skill by calling a synthesized tool |
| Chat completions client | `LanguageModels/ChatCompletionsLanguageModel.swift` | A `LanguageModel` conformance that talks to any OpenAI-compatible `/chat/completions` server, with flags for servers that lack guided generation |

## How it relates to CollaborationKit

CollaborationKit **does not integrate FoundationModels today**. The only
mention in the repo is RFC 0003, which *proposes* a bridge (issue #16). So
there is nothing here to delete or replace — the question is purely whether
to depend on it or borrow from it.

Two hard blockers against depending on it:

1. **Deployment target.** CollaborationKit ships `.macOS(.v14) / .iOS(.v17)`.
   The package requires OS 27. Adding it as a dependency would either raise
   our floor by a decade of OS releases or force a separate availability-gated
   target.
2. **Different substrate.** Every symbol in the package is expressed in
   `FoundationModels` vocabulary. CollaborationKit has its own `LLMSession`,
   `Message`, `Tool`, and `CompactionStrategy`. Nothing is reusable without
   the FoundationModels types coming along.

License is not a blocker (Apache-2.0 into an MIT project is fine with
attribution) but vendoring source would mean carrying their headers.

## Concept overlap worth stealing

- **History modifiers ↔ `CompactionStrategy`.** We ship
  `NoCompactionStrategy` and `KeepRecentCompactionStrategy`. Two of theirs
  have no equivalent here and are cheap to build on our own protocol:
  - dropping *completed* tool calls (keep the call, drop the bulky result)
    — the highest-value trim for tool-heavy sessions, and it doesn't lose
    conversational thread;
  - summarizing the dropped prefix into a single entry via a second
    (possibly smaller) model, instead of discarding it.
  Their composition story (modifiers stacking outside-in) is also a better
  shape than our single-strategy slot.
- **Skills ↔ #49.** Their design answers the questions #49 lists: skills are
  surfaced to the model as tools; a *prompt*-based skill's body lands in the
  tool output (so the KV cache survives), while an *instructions*-based skill
  is spliced into the instructions entry (higher obedience, cache
  invalidation) and can optionally be deactivated later. `SkillActivations`
  is `Observable` so a UI can show what's active. Good reference design when
  #49 gets picked up.
- **`ChatCompletionsLanguageModel` ↔ our OpenAI provider.** Overlapping but
  inverted: theirs adapts a remote server *into* FoundationModels, ours
  adapts backends into our own session. Their capability flags (servers
  without guided generation, reasoning-content handling) mirror decisions we
  already made for LM Studio / Ollama. Nothing to reuse.

## Decision

**Don't depend, don't vendor. Borrow the patterns.**

Revisit only if RFC 0003's FoundationModels bridge (#16) lands *and* the
package's OS 27 floor stops being a problem — at which point the history
modifiers could ride along inside the availability-gated bridge target
rather than in core.
