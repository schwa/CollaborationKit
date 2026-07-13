# RFC 0004 — SwiftData Bridge for `@CollaborationTools`

- **Status:** Draft
- **Author:** @schwa
- **Created:** 2026-07-13
- **Affects:** `CollaborationKitMacros` (macro impl), new runtime module
  `CollaborationKitSwiftData` (filter/predicate helpers), `Sources/CollaborationKit`
  (no changes expected).
- **Related:** RFC 0003 §3.2, issue #17, issue #14 (Slice 1 landed).

## Summary

Annotating a SwiftData `@Model` class with `@CollaborationTools` should
synthesize a small, opinionated CRUD toolbox — `list`, `fetch`, `create`,
`update`, `delete` — plus a `collaborationTools(in: ModelContext)` accessor
that binds those tools to a concrete context. Which properties are readable,
writable, or hidden is controlled by `@CollaborationField` per property.
Hand-written `@CollaborationTool` methods on the same type always win over
the derived tool of the same name.

## Motivation

Slice 1 does not know about SwiftData. `@CollaborationTools` on a `@Model`
class today emits an empty toolbox unless the user hand-writes each CRUD
method. That is the exact boilerplate this project exists to remove: a
`@Model` already declares its stored properties, their types, and (via
`@Attribute`) their constraints. The macro has enough information to
generate a competent default surface.

The bridge is opinionated on purpose. General relational access through an
LLM is a foot-gun — arbitrary predicates, joins, and cascading writes are
not what we want a model to reach for. The derived surface is the "safe
default"; anything richer goes through a hand-written `@CollaborationTool`
using the nested-object rule (IDs across the wire, host-owned lookup
inside).

## Design

### 1. Macro detection

The macro decides "this is a SwiftData model" by looking for the `@Model`
attribute on the enclosing type at expansion time — a syntactic check, no
runtime introspection. If `@Model` is present, the macro **adds** derived
CRUD tools to whatever the user hand-wrote (subject to the override rule
below). If `@Model` is absent, behavior is unchanged from Slice 1.

Requires no new opt-in attribute. `@CollaborationTools` on a `@Model` class
is the trigger.

```swift
import SwiftData
import CollaborationKit

@Model
@CollaborationTools
final class Note {
    var title: String
    var body: String
    @Attribute(.unique) var id: UUID = UUID()
    @CollaborationField(.readOnly) var createdAt: Date = .now
    @CollaborationField(.hidden)   var internalRevision: Int = 0
}

let context: ModelContext = ...
let session = LLMSession(
    provider: provider,
    tools: Note.collaborationTools(in: context)
)
```

### 2. Derived tools

For a `@Model` type `T` with identifier property `id`, the macro emits five
tools:

| Tool             | Purpose                                | Input                                            | Output                     |
| ---------------- | -------------------------------------- | ------------------------------------------------ | -------------------------- |
| `list_T`         | Enumerate rows, optionally filtered.   | `filter?: Filter, sort?: [SortDescriptor], limit?: Int, offset?: Int` | `[T-snapshot]`             |
| `fetch_T`        | Look up one row by id.                 | `id: T.ID`                                       | `T-snapshot` (or `null`)   |
| `create_T`       | Insert a new row.                      | writable fields                                   | `T.ID`                     |
| `update_T`       | Mutate an existing row.                | `id: T.ID` + optional writable fields             | `T-snapshot`               |
| `delete_T`       | Delete a row by id.                    | `id: T.ID`                                       | `"OK"`                     |

Names default to `list`, `fetch`, `create`, `update`, `delete` and are
prefixed with the type name via the existing `@CollaborationTools(prefix:)`
rule. Passing `prefix: "note"` yields `note_list`, `note_fetch`, etc.

### 3. `@CollaborationField`

Peer attribute on stored properties. Values:

- `.writable` (default) — appears in schemas for `create_T`, `update_T`,
  `list_T` filter/sort, and in `T-snapshot`.
- `.readOnly` — appears in `list_T`/`fetch_T` output and in `update_T`'s
  filter/sort, but **not** in `create_T` or `update_T` inputs.
- `.hidden` — never crosses the wire. The model does not see the property
  exists.
- `.id` — marks this property as the identifier used by `fetch_T`,
  `update_T`, and `delete_T`. Exactly one property must carry `.id`. If
  omitted, the macro picks the first stored property named `id` (any
  supported type). If neither is present, diagnose at expansion time.

Rationale: SwiftData's `PersistentIdentifier` is not JSON-friendly, is not
stable across launches until save, and is not the identity most apps
actually want to expose to a model. Users almost always have their own
`UUID` / `String` id. The macro assumes so and lets them tell it which
property that is.

### 4. Field type support

Field types the macro handles for both schema and mutation:

- All Slice 1 primitives (`Bool`, `Int`, `Double`, `Float`, `String`).
- `Optional<T>`, `Array<T>`, `[String: T]` recursively.
- `Date` — schema is `{"type":"string","format":"date-time"}`, ISO-8601
  round-trip.
- `URL` — schema is `{"type":"string","format":"uri"}`.
- `Data` — schema is `{"type":"string","contentEncoding":"base64"}`.
- Any type conforming to `CollaborationSchemaConvertible` (the Slice 1
  escape hatch, including `RawRepresentable` id wrappers).
- **Relationships** to another `@Model` `U`: exposed as `U.ID` (not the
  nested object). Setting a relationship on `create`/`update` means "look
  up the referenced row by id in the same `ModelContext`". If the id does
  not resolve, the tool throws `ToolError`. To-many relationships take
  `[U.ID]`.

Anything else — computed properties, transient properties, unsupported
value types — is silently omitted from the derived surface. `@Attribute(.transient)`
and `@Transient` are treated as `.hidden`.

### 5. Filter schema (`list_T`)

Filters are declarative, not a `Predicate` DSL. The macro emits a JSON
Schema that admits a fixed grammar per field type:

- String / URL fields: `{ "equals": "…" }`, `{ "contains": "…" }`,
  `{ "startsWith": "…" }`.
- Number / Date fields: `{ "equals": … }`, `{ "lessThan": … }`,
  `{ "greaterThan": … }`, `{ "between": [min, max] }`.
- Bool fields: `{ "equals": true|false }`.
- Optional-of-supported: additionally `{ "isNull": true|false }`.
- Relationship-id fields: `{ "equals": "…" }`, `{ "in": ["…", "…"] }`.

The top-level filter object is an AND over per-field filters:

```json
{
  "filter": {
    "title": { "contains": "todo" },
    "createdAt": { "greaterThan": "2026-01-01T00:00:00Z" }
  },
  "sort": [{ "field": "createdAt", "order": "descending" }],
  "limit": 20,
  "offset": 0
}
```

Compound OR/NOT and nested boolean expressions are **out of scope for this
RFC**. If a caller needs richer queries, the escape hatch is a hand-written
`@CollaborationTool func search(...)` that builds a real `Predicate`
in-process. This mirrors RFC 0003's stance on schema surface: keep the
model-facing grammar small, keep power in hand-written Swift.

Runtime side: `CollaborationKitSwiftData` (new module) exposes a
`SwiftDataFilter<T>` decoder that turns the JSON above into a
`Predicate<T>`. The macro emits code that decodes into `SwiftDataFilter<T>`
and hands the resulting predicate to `FetchDescriptor<T>`.

### 6. `T-snapshot`

`list_T`, `fetch_T`, and `update_T` return a JSON object per row. The
snapshot is derived, not the model itself: it contains the `id` plus every
`.writable`/`.readOnly` field, with relationships flattened to `U.ID` /
`[U.ID]`. Snapshots are `Encodable` and go through `_ckStringify` like any
other tool return value.

The snapshot is *not* a separate Swift type in the public surface — it is
JSON produced by the derived tool. If the user wants a typed snapshot,
they can hand-write a tool that returns their own struct.

### 7. Accessor

Because every derived tool needs a `ModelContext`, the macro emits a
context-taking accessor rather than the parameterless `collaborationTools`
from Slice 1:

```swift
extension Note {
    public static func collaborationTools(
        in context: ModelContext
    ) -> [any Tool]
}
```

Slice 1's `collaborationTools` (instance property, no context) is not
emitted for `@Model` types — instance methods on a `@Model` class do not
make sense as a per-instance toolbox in the CRUD case. If the user
hand-writes an instance `@CollaborationTool` method on a `@Model`, they
get a compile-time diagnostic pointing them at the static accessor.

### 8. Precedence and override

- User-written `@CollaborationTool` on the type replaces the derived tool
  of the same **exposed name** (after prefixing).
- User-written `@CollaborationField(.hidden)` on the id property is a
  diagnosed error — the CRUD surface needs an id.
- Setting `prefix:` on `@CollaborationTools` re-prefixes derived tools
  identically to hand-written ones.

Override happens by matching on the final exposed tool name, not by Swift
symbol. This is what lets the user replace `note_list` with a smarter
custom implementation without changing the model class.

### 9. Concurrency

`ModelContext` is not `Sendable`. The generated `call(_:)` methods hop to
the context's actor before touching it. Concretely: each derived tool
captures the `ModelContext` and its `mainContext`-ness at construction
time and dispatches accordingly:

- If the context is `ModelContext.mainContext` (or the user opts in via a
  `mainActor: true` flag on the accessor), the tool body runs on
  `@MainActor`.
- Otherwise the tool body runs on a dedicated executor keyed off the
  context. This is enough for the common in-app case (`mainContext`) and
  the common test case (a background context per test).

Open question: whether we can express this without a separate `mainActor:`
flag by inspecting the context at runtime. Punt to prototype.

### 10. Target layout

```
Sources/
  CollaborationKitMacros/
    Bridges/
      SwiftDataBridge.swift        # macro-side detection + codegen
  CollaborationKitSwiftData/       # new runtime module
    Filter/
      SwiftDataFilter.swift        # JSON → Predicate<T>
      SortDescriptor.swift
    Snapshot/
      SnapshotEncoder.swift
    OSVersionGate.swift
```

`CollaborationKitSwiftData` is a separate library product so callers who
do not use SwiftData pay nothing. It depends on `CollaborationKit`.

The macro itself lives in the existing `CollaborationKitMacros` target —
it does not import SwiftData (it cannot; macros run in the compiler
plugin process). It emits code that references `SwiftData` and
`CollaborationKitSwiftData` symbols; the user's target must import both.

### 11. Availability

SwiftData is macOS 14 / iOS 17 — the current package floor. No availability
attribute needed on the runtime module.

The generated code guards `@available(macOS 14, iOS 17, *)` around each
derived tool struct so a hypothetical future package floor drop does not
break users who annotate a `@Model` in a lower-deployment target. This is
belt-and-braces, cheap to keep.

### 12. Diagnostics

At expansion time:

- Missing id property → error: "Add `@CollaborationField(.id)` to a stored
  property, or name one `id`."
- More than one `.id` → error.
- `@CollaborationField(.hidden)` on the id property → error.
- Relationship to a non-`@Model` type → error, pointing at
  `CollaborationSchemaConvertible`.
- Unsupported field type on a non-`.hidden` property → warning (not
  error), silently omit from surface. Users often mix in obscure types
  they do not want the model to see anyway; warning gives them a nudge
  without breaking the build.

## Slicing

The bridge is too big for one PR. Proposed order — each slice ships
independently and closes real value.

**Slice A — read-only surface.** `list_T` (no filter), `fetch_T`,
`T-snapshot`, `.readOnly`/`.hidden` handling, accessor plumbing,
`CollaborationKitSwiftData` module skeleton. No mutations, no filters,
no relationships. Lands the framework detection and the accessor shape.

**Slice B — filter and sort.** `filter`, `sort`, `limit`, `offset` on
`list_T`. Ships `SwiftDataFilter<T>` decoder. Still no mutations.

**Slice C — mutations.** `create_T`, `update_T`, `delete_T`.
`.writable` semantics, `.id` handling. Concurrency plumbing.

**Slice D — relationships.** To-one and to-many relationships as ids;
lookup during create/update; snapshot flattening. This is the slice most
likely to churn — parking it last means the CRUD surface is proven first.

Each slice gets its own issue rolling off #17. #17 closes when Slice D
ships.

## Testing

- Macro expansion tests via `SwiftSyntaxMacrosTestSupport` — one golden
  file per slice covering the derived struct shapes, the accessor, the
  filter schema.
- Integration tests in `CollaborationKitTests` under
  `#if canImport(SwiftData)` gates, using an in-memory `ModelContainer`.
  Cover: create/fetch round-trip, update partial-fields, delete, filter
  precedence, sort stability, snapshot shape, override rule.
- Concurrency tests: derived tool called from a non-main task against a
  `mainContext` model runs to completion without a data-race trap under
  `-strict-concurrency=complete`.

## Non-Goals

- Rich `Predicate` DSL exposure. See §5.
- Migration / schema-versioning tools.
- Cascading deletes exposed as an option to the model. Cascade is a
  SwiftData `@Relationship(deleteRule:)` concern; the derived `delete_T`
  respects whatever the user configured. Adding a runtime toggle would
  invite the model to nuke half the store.
- CloudKit-specific behavior. If the underlying store is CloudKit-backed
  the tools work, but the derived surface makes no promises about
  cross-device timing.
- Batch operations (`createMany`, `deleteMany`). Composable from repeat
  calls; the model can loop. Revisit if profiling shows it matters.

## Open Questions

1. **Auto-id inference.** Is "first stored property named `id`" too
   magic? Alternative: require `@CollaborationField(.id)` explicitly.
   Prototype both, see which reads better in tests.
2. **Concurrency gating.** Can we detect `mainContext` at runtime cleanly,
   or do we need the `mainActor:` flag on the accessor? (§9.)
3. **Save policy.** Does `create` / `update` / `delete` call
   `context.save()` implicitly, or leave it to the host? Leaning "leave
   it" — matches SwiftUI-style implicit saves, and the model shouldn't
   be committing on the host's behalf. Needs a decision before Slice C.
4. **Snapshot depth.** For to-one relationships, snapshot is
   `relatedID: "…"`. Should we also allow an opt-in "inline one level
   deep" via `@CollaborationField(.inline)`? Probably yes eventually,
   not in this RFC.
5. **Error surface.** SwiftData errors are not obviously safe to surface
   verbatim to the model. Map to `ToolError("failed to …")` with the
   underlying error's `localizedDescription`? Or a stricter allowlist?
6. **Read vs. write approval.** RFC 0003 exposes `requiresApproval` on
   the attribute. Does the SwiftData bridge default `create` / `update` /
   `delete` to `requiresApproval: true`? Leaning yes — mutations against
   the user's local store should surface at least once so hosts can gate
   them. Overridable per-model via a `@CollaborationTools` argument.

## Alternatives Considered

- **Separate `@CollaborationModel` macro** rather than overloading
  `@CollaborationTools`. Rejected: users already reach for
  `@CollaborationTools`, and framework-aware behavior is exactly what
  RFC 0003 promised. One entry point beats two.
- **Expose `Predicate<T>` directly.** Rejected: not `Codable`, not a JSON
  schema, and gives the model the ability to write arbitrary queries.
- **Derive tools from `@Attribute` alone, skip `@CollaborationField`.**
  Rejected: `@Attribute` doesn't carry the "hide from LLM" concept, and
  overloading it would force users to change their persistence schema
  to change their tool surface.
- **Auto-emit `save` after every mutation.** See open question 3.
