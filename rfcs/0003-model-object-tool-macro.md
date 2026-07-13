# RFC 0003 — Model-Object Tool Macro

- **Status:** Draft
- **Author:** @schwa
- **Created:** 2026-07-12
- **Affects:** New target `CollaborationKitMacros` (macro implementation) and
  a public macro surface in `CollaborationKit`.
- **Related:** README "Tools" section; `Tool` / `AnyTool` in `Core/`.

## Summary

Add a Swift macro that turns an arbitrary model object into a set of
`CollaborationKit` tools automatically — without hand-writing an `Input`
struct or a JSON Schema for each tool. One `@CollaborationTools` (working
name) attached to a type exposes selected methods/properties as tools an
`LLMSession` can call.

The same macro layer explicitly supports bridging from adjacent Apple
frameworks so the same model works whether it was authored for
`FoundationModels`, `SwiftData`, or `AppIntents`, and users can sprinkle
attributes to override or extend the derived surface.

## Motivation

Today, adding a tool is:

1. Write a type conforming to `Tool`.
2. Write a `Decodable & Sendable Input`.
3. Hand-write a JSON Schema in `JSONValue`.
4. Wire the `call(_:)` handler to whatever the app already has.

For an app that already models its domain as objects (view models,
`@Observable` stores, `SwiftData` `@Model`s, `AppIntent`s, or a
`FoundationModels` `@Generable`), that is triplicated boilerplate. The
macro removes it: existing types become tools by annotation.

The README already commits to "Typed tools, not JSON. Do not auto-derive
schemas from `Codable`." This RFC does *not* violate that — it derives from
explicit annotations and known framework metadata, not from `Codable`
introspection.

## Design

### Public surface (sketch)

```swift
// Attach to a type; expose annotated members as tools.
@CollaborationTools
final class NoteStore {

    @CollaborationTool("List all notes.")
    func list() -> [Note] { ... }

    @CollaborationTool("Create a note with the given title and body.")
    func create(title: String, body: String) -> Note.ID { ... }

    @CollaborationTool("Delete the note with this ID.")
    func delete(id: Note.ID) throws { ... }

    // Not exposed — no attribute.
    func internalHousekeeping() { ... }
}

let store = NoteStore()
let session = LLMSession(
    provider: provider,
    tools: store.collaborationTools  // synthesized
)
```

The macro synthesizes, per annotated member:

- An `Input` struct (`Decodable & Sendable`) from the parameter list.
- A JSON Schema (`JSONValue`) derived from parameter types and doc strings.
- A `Tool` conformer whose `call(_:)` invokes the original member.
- A `collaborationTools: [AnyTool]` accessor on the enclosing type.

Names default to the Swift member name; descriptions come from the attribute
argument (or the member's doc comment).

### Supported parameter/return types (initial)

- Primitives: `Bool`, `Int`, `Double`, `String`.
- `Optional<T>` where `T` is supported.
- `Array<T>` / `Dictionary<String, T>` where `T` is supported.
- Types conforming to a new `CollaborationSchemaConvertible` protocol (the
  escape hatch) — the macro emits a call to their schema, doesn't invent one.
- Nested `@CollaborationTools`-annotated types by ID reference, not by
  value inlining (see Open Q3).

Return values are stringified via `CollaborationResultConvertible`
(default conformances for `String`, `LosslessStringConvertible`, `Encodable`
via JSON). Errors thrown from the member map to `ToolError` per the README's
error-split rule.

### Framework bridges

Each bridge is a separate module under `CollaborationKitMacros/` so users
only pay for what they import.

#### 3.1 `FoundationModels`

- Recognise `@Generable` types as first-class parameter/return types — reuse
  their generated schema instead of re-deriving one.
- Provide `@CollaborationTool` overlays on functions that take/return
  `@Generable` values; the schema comes straight from `FoundationModels`.
- Optional companion macro to expose a `FoundationModels` session's own
  tools through the CollaborationKit `Tool` surface, so an app can use one
  toolbox with either backend.

#### 3.2 `SwiftData`

- Annotate a `@Model` class with `@CollaborationTools` and get CRUD tools
  for free: `list`, `fetch(id:)`, `create(...)`, `update(id:, ...)`,
  `delete(id:)`.
- Which fields are readable / writable is controlled by
  `@CollaborationField(.readOnly | .hidden | .writable)` per property.
- Predicate parameters map to a small, declarative filter schema — not
  arbitrary `Predicate` DSL. Escape hatch: a user-written `@CollaborationTool
  func search(...)` always beats the derived one.
- Requires a `ModelContext`; the accessor takes it: `store.collaborationTools(in: context)`.

#### 3.3 `AppIntents`

- Recognise types conforming to `AppIntent` and expose their `perform()` as
  a tool, with parameters derived from `@Parameter` metadata (title,
  description, default value, options).
- Parameter summaries and localised titles feed the tool description.
- Returned `IntentResult` maps through `CollaborationResultConvertible`
  (dialog text → tool result string; opened content → structured result).
- Does not require the app to actually route intents through the system —
  the macro can call `perform()` directly for in-process use.

#### 3.4 User-sprinkled macros

The primitives above are exposed as public macros so users can decorate
their own types outside any framework bridge:

- `@CollaborationTools` on a type.
- `@CollaborationTool("…")` on a method.
- `@CollaborationField(.readOnly)` on a property.
- `@CollaborationSchema` on a value type to opt into schema derivation
  (documented list of supported members).

Everything the bridges do is expressible with these; the bridges are just
opinionated defaults.

### Target layout

```
Sources/
  CollaborationKit/
    Macros/PublicMacros.swift        // @CollaborationTools etc., re-exports
  CollaborationKitMacros/            // macro impls (SwiftSyntax)
    ToolsMacro.swift
    SchemaDerivation.swift
    Bridges/
      FoundationModelsBridge.swift
      SwiftDataBridge.swift
      AppIntentsBridge.swift
```

Availability follows each framework: FoundationModels / SwiftData / AppIntents
bridges gate on their respective OS versions; the core macro works on the
current package minimum (macOS 14+, Swift 6).

## Open Questions

1. **Schema fidelity.** How far do we derive schemas from Swift types before
   requiring `CollaborationSchemaConvertible`? Enums with associated values?
   Generics? Tuples? Start small.
2. **Doc-comment mining.** Do we read `///` comments for descriptions, or
   require the attribute argument? Doc comments are nicer but macros only see
   trivia if we ask for it.
3. **Nested objects.** Passing a whole nested model as a tool argument vs.
   passing an ID that the tool then dereferences. Prefer IDs; document why.
4. **Concurrency.** Tools called through `LLMSession` are async / sendable.
   The macro must generate `await` / actor-hopping code correctly for
   `@MainActor` model objects, `@Model` classes on a `ModelContext`, and
   `AppIntent.perform()`.
5. **Tool naming collisions.** When two annotated types expose `create`,
   what does the model see? Prefix with the owning type name by default,
   overridable per-attribute.
6. **Auth / gating.** Some derived tools (delete, update, perform an intent)
   have real side effects. Do we surface a `requiresApproval` flag on the
   attribute, or leave gating entirely to the host? README says host's
   concern — keep it that way, but expose enough metadata that a host can
   act on it.
7. **Testing.** Macro expansion tests via `SwiftSyntaxMacrosTestSupport`.
   Bridge tests must not require the actual framework at runtime where
   avoidable (SwiftData/FoundationModels availability).

## Non-Goals

- Deriving schemas from `Codable` conformances. Still explicitly out — the
  macro uses attributes + known framework metadata.
- Replacing the hand-written `Tool` conformance. It remains supported and
  is the recommended path for complex or performance-sensitive tools.
- Any UI. Presentation of tool calls (approval prompts, progress) is
  RFC 0002's problem.

## Alternatives Considered

- **Runtime reflection via `Mirror`.** Rejected — not Sendable-friendly,
  not typed, and can't see attributes.
- **Codable-derived schemas.** Rejected per README constraint.
- **Separate macros per framework, no shared core.** Rejected — the
  primitives are the same; framework bridges should compose on top.
