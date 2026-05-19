# Swift model codegen (`swift-bao-codegen`)

> **Reading this from a JS background?** Skim
> [TS↔Swift codegen, side by side](#tsswift-codegen-side-by-side) and
> [Swift in 5 minutes for a JS reader](#swift-in-5-minutes-for-a-js-reader)
> first. The rest of the doc assumes you've internalized the few
> Swift concepts that don't have a clean JS analog.

`swift-bao-codegen` does the same job as the TS codegen
(`js-bao-codegen-v2`): turn a `models.toml` into typed model code at
build time so the TOML is the single source of truth across both
clients. The interesting differences are *shape* — the Swift output
looks heavier than the TS output, the typed CRUD path goes through a
wrapper class instead of methods on the type itself, and the schema
shows up twice in each file. Most of this doc is about *why* each of
those choices is the way it is, and how to keep your hand-written
code thin on top.

**Codegen is the canonical path** for any Swift app whose schema is
known at build time. See [Schema sources](#schema-sources--when-to-use-what)
below for the (narrower) alternatives.

## TL;DR — why this shape?

**Why do generated structs ship with inits and serialization methods instead of inheriting from a base class?**
Swift structs can't inherit, and protocols can't carry stored state. So there's no equivalent of TS's `class Contact extends BaseModel {}` — every record needs its own real stored properties plus four bridge methods (designated init, `init?(record:)`, `init?(row:)`, `primitiveValues()`) that connect them to the runtime.

**Why does CRUD go through `TypedModel<T>(doc:)` instead of `TaskRecord.find(id:)`?**
The doc handle is shared state — `find` and `query` need a stable place to read the doc, SQLite mirror, and observer queue from. Structs are values, copied on every assignment, so they can't be that stable home. Classes can. The doc lives on `TypedModel<T>` (a class), and records are values it produces and consumes.

**Why not just make records classes too, and put `find` on them directly?**
In one sentence: classes get you a smaller codegen leaf but cost you four things Swift gives structs for free — independent `@State` copies for SwiftUI form drafts (`@State var draft = task` clones, doesn't share), naked records for previews and tests, synthesized `Equatable` / `Hashable` / `Codable`, and value-diff change tracking — and you end up rebuilding ~half of TS's `BaseModel` runtime in Swift to recover them. [Why two layers](#why-two-layers-typed-struct--typedmodelt-wrapper) has the full breakdown.

**This isn't a stylistic preference — it's backed up two ways:**
- **Apple's own guidance.** [Choosing between structures and classes](https://developer.apple.com/documentation/swift/choosing-between-structures-and-classes) says to use structs by default and reach for classes only when you specifically need reference semantics or Objective-C interop. Records are data; structs are the default.
- **We tried it.** The class-based codegen lives on `feat/swift-model-codegen-with-classes` (commits `601fe789` "move CRUD onto BaseRecord protocol; drop TypedModel<T> wrapper" and `2088fae1` "add @Observable + identity map"). The leaf did shrink ~40%, but the cost showed up immediately: a per-doc identity map to stop `T.find(id)` from returning two non-equal instances of the same record, hand-emitted `init(from:)` / `encode(to:)` / `CodingKeys` per leaf because `@Observable` breaks `Codable` auto-synth (~25 lines/model back), `@ObservationIgnored` on every backtick-escaped field name (silent loss of SwiftUI reactivity on legal field names), and the collapse of the `@State var draft = task` form-drafting pattern. The complexity adds up fast trying to chase TS's minimal-leaf shape.

## Why

Without codegen, every model needs ~60 lines of mechanical boilerplate
(stored properties, three inits, `primitiveValues()`, schema literal)
that's just a projection of the TOML. Every drift between the TOML and
the Swift is a bug waiting to bite at runtime. Codegen makes the TOML
the source of truth and turns hand-written drift into "did the
codegen run?", which is enforceable at build time.

## TS↔Swift codegen, side by side

Same TOML in, both codegens run, here's what falls out.

### Input (the same `models.toml` both clients read)

```toml
[models.contacts]
[models.contacts.fields.id]
type = "id"
[models.contacts.fields.name]
type = "string"
[models.contacts.fields.email]
type = "string"
```

### TS output (`Contact.generated.ts`)

```ts
import type { BaseModel } from "js-bao";
import { BaseModel as BaseModelImpl } from "js-bao";

export interface ContactAttrs {
  id: string;
  name?: string;
  email?: string;
}

export interface Contact extends ContactAttrs, BaseModel {}
export class Contact extends BaseModelImpl {}
export const Contact_modelName: "contacts" = "contacts";
```

That's the entire file. The `class Contact extends BaseModelImpl {}`
gets every CRUD method (`save`, `find`, `query`, prototype proxy for
field reads/writes) by inheritance. The `interface Contact` provides
typed field access at compile time only — there's no runtime cost to
the interface declaration.

### Swift output (`ContactRecord.swift`)

```swift
internal struct ContactRecord: PrimitiveModel, Equatable, Hashable, Codable {
    internal static let modelName = "contacts"
    internal static let primitiveSchema = PrimitiveSchema(
        name: "contacts",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "name":  FieldDescriptor(type: .string),
            "email": FieldDescriptor(type: .string),
        ]
    )

    internal var id: String
    internal var name: String?
    internal var email: String?

    internal init(id: String, name: String? = nil, email: String? = nil) {
        self.id = id; self.name = name; self.email = email
    }
    internal init?(record: PrimitiveRecord) { /* … */ }
    internal init?(row: [String: Any]) { /* … */ }
    internal func primitiveValues() -> [String: PrimitiveValue] { /* … */ }
}
```

CRUD then goes through a wrapper:

```swift
let model = TypedModel<ContactRecord>(doc: doc)
let c = try model.create(ContactRecord(id: "c1", name: "Ada"))
let found = model.find(id: "c1")
let all = model.findAll()
```

### What's the same

| Concern | TS | Swift |
|---|---|---|
| Source of truth | `models.toml` | `models.toml` (same file, identical schema) |
| Banner-protected output | `// AUTO-GENERATED FROM models.toml — DO NOT EDIT.` | `// Generated by swift-bao-codegen — DO NOT EDIT.` |
| Field declarations | one entry per field in `ContactAttrs` interface | one stored property per field on the struct |
| Required vs optional | `name: string` vs `name?: string` | `name: String` vs `name: String?` |
| Field metadata at runtime | resolved from the BaseModel registry (decorators / static config) | embedded in the file as `static let primitiveSchema` |

### What's different

| | TS | Swift |
|---|---|---|
| Generated body | nearly empty (`class Contact extends BaseModelImpl {}`) | full struct with 4 init/serialize methods |
| CRUD entry | methods on the generated class itself: `Contact.find(...)`, `instance.save()` | wrapper class `TypedModel<ContactRecord>(doc:)` carries the doc handle and surfaces `find` / `query` / `create` |
| Equality | reference equality (default JS `===`) | value equality (`Equatable`) — generated for free |
| JSON | not provided by codegen | `Codable` — generated for free |
| State location | TS `Contact` instance carries doc state internally (BaseModel proxies field reads to the CRDT) | Swift `ContactRecord` is a pure value with no doc state; the doc handle lives on the `TypedModel<T>` wrapper |

The "Why is the Swift output bigger?" answer has three pieces:
real stored properties (Swift has no interface-style declaration
merging), real (de)serialize bodies (no prototype/proxy machinery),
and split state between the value-type record and the reference-type
model wrapper. Full explanation in
[Why isn't the Swift output as light as TS?](#why-isnt-the-swift-output-as-light-as-ts).

## Swift in 5 minutes (for a JS reader)

Just enough Swift to follow the rest of the doc. If TS is your home
language, most of this is "X but with type-system enforcement and a
runtime cost story".

**Optionals (`T?`).** Swift's `T?` is roughly TS `T | null | undefined`,
but it's *enforced* — you can't pass a `String?` to a function that
takes a `String` without unwrapping. The codegen turns `required = true`
fields into `T` and everything else into `T?`. The dot-chain
`record.name?.uppercased()` is the same shape as TS's optional
chaining.

**`struct` vs `class`.** This is the big one. Both have init,
methods, computed properties, and protocol conformances. The
differences:

| | `struct` | `class` |
|---|---|---|
| Memory | value (copy on assignment) | reference (shared by pointer) |
| Identity | none — `==` compares fields by `Equatable` | reference identity (`===`) |
| Inheritance | conform to protocols only; cannot extend a base struct | single inheritance + protocol conformance |
| Mutability | controlled per binding (`let myStruct` is fully immutable) | `let myClass` is a const reference; properties stay mutable |
| Lifetime | scope-bound, like a value on the stack | reference-counted (ARC), like a JS object |
| Closest JS analog | a frozen plain object / record | a class instance with `this` |

Codegen-emitted records are structs; the wrapper is a class. The
[Why two layers](#why-two-layers-typed-struct--typedmodelt-wrapper)
section spells out why.

**`protocol`.** A protocol is roughly a TS interface that lets
default method bodies tag along (via
`extension Protocol where Self: ...`). A type "conforms to" a
protocol the same way a TS class implements an interface.
`PrimitiveModel` is the protocol every codegen-emitted struct
conforms to.

**Both structs *and* classes can have methods.** Swift's `struct` is
not the C `struct` you might be picturing — it's full-featured. The
only Swift-language thing structs *can't* do that classes can is
`class`-style inheritance (`struct Foo: Bar` where `Bar` is also a
struct is a syntax error). They can conform to any number of
protocols and have init, mutating methods, computed properties, etc.

**Generics with constraints.** `TypedModel<T: PrimitiveModel>` reads
"generic class parameterized by some `T` that conforms to
`PrimitiveModel`". Same shape as TS's
`class TypedModel<T extends PrimitiveModel>`.

**Failable initializers (`init?`).** A regular `init(...)` always
succeeds. `init?(...)` returns `Self?` — `nil` if construction
fails. Codegen uses this for "read from CRDT or SQLite row, return
nil if a required field is missing" — so a typed `find(...)` can
degrade to `nil` while the dynamic record stays inspectable.

**`@discardableResult`, `final class`, `@MainActor`.** Just
attributes you'll see in the source. `@discardableResult` ≈ "don't
warn if the caller ignores the return value", `final class` ≈ "no
subclasses". You can ignore them while reading.

## Why two layers: typed struct + `TypedModel<T>` wrapper

> **Q: I write `Contact.find(id)` in TS. Why can't I write
> `TaskRecord.find(id:)` in Swift?**

Because `TaskRecord` is a value type (`struct`) with no doc handle.
Running a query needs a CRDT doc, a SQLite mirror, and an observer
queue — none of which can live on a value type that gets copied on
every assignment. So the codegen splits two responsibilities:

- **`TaskRecord`** — pure value. Just fields + four serialization
  methods + a static schema. Cheap to copy, equality by content,
  Codable-friendly. SwiftUI and Combine are designed around values,
  so making the record a value is the right answer for diffing,
  view re-render, and undo.
- **`TypedModel<TaskRecord>(doc:)`** — `final class` that holds the
  doc handle and the SQLite mirror, and surfaces `find` / `findAll` /
  `query` / `create` / `update` / `delete` typed against
  `TaskRecord`.

In TS, a `Contact` instance plays both roles at once because TS
classes carry instance state and `BaseModel` proxies field access
through to the underlying CRDT — `contact.name = "x"` *is* a CRDT
write. The same shape in Swift is technically possible (class
records, `@Observable` for SwiftUI tracking, an identity map so
two `find()` calls return the same instance), but the trade-off
goes the other way for app code. Here's why, with concrete
examples.

### Why structs (not classes) for the record

The class-based path would buy us TS-style ergonomics: methods on
the type (`Contact.find(...)`), live binding (mutate the instance
to write the CRDT), no wrapper layer. Real wins. We pick structs
anyway because the wins on the *struct* side are language-level
features Swift hands you for free, while the class wins are mostly
features we'd have to *build* in Swift. Three concrete wins
spelled out.

#### Win 1: `@State` form drafting just works

Real form-editing pattern in a SwiftUI app:

```swift
struct TaskEditor: View {
    @State var draft: TaskRecord
    let onSave: (TaskRecord) -> Void

    var body: some View {
        Form {
            TextField("Title", text: $draft.title)
            Stepper("Priority \(Int(draft.priority ?? 0))",
                    value: Binding(
                        get: { draft.priority ?? 0 },
                        set: { draft.priority = $0 }
                    ))
            Button("Save") { onSave(draft) }
            Button("Cancel") { dismiss() }
        }
    }
}
```

`@State var draft: TaskRecord` makes a real, independent copy of
the record. The TextField binds to `draft.title` directly;
mutations stay local to the form. On Save the parent calls
`model.update(...)`. On Cancel the draft is just thrown away.

With class records, every `draft` is a reference to the *live*
record. `draft.title = "new"` would write to the CRDT immediately
— the user typing in the form would broadcast every keystroke to
other clients. To draft locally you'd either:

- keep edit state separately as a bag of `@State` vars and
  reassemble on save (the TS convention), or
- emit a `func detached() -> Self` on every model that hand-clones
  every field, plus a `model.commitDraft(_:into:)` to push back.

The struct version is one line of language idiom. The class
version is a convention you have to learn or a runtime you have
to write.

#### Win 2: Naked records for previews / tests / fixtures

```swift
#Preview {
    TaskRow(task: TaskRecord(id: "preview-1", title: "Buy milk"))
}

func test_priorityOrdering() {
    let high = TaskRecord(id: "1", priority: 5, title: "x")
    let low  = TaskRecord(id: "2", priority: 1, title: "y")
    XCTAssertGreaterThan(high.priority!, low.priority!)
}
```

`TaskRecord(id:title:)` is a fine in-memory value — no doc, no
setup, no `YDocument()` boilerplate. SwiftUI previews and unit
tests work without spinning up a CRDT.

With class records, every instance assumes it's bound to a doc.
A naked `TaskRecord(id: "x", title: "y")` either silently goes
nowhere on mutation, or you add a `.detached` mode with runtime
guards. Either way, the type means two different things depending
on how it was constructed — every method needs to know which.

#### Win 3: `Set` / `Dictionary` / `Equatable` just work

```swift
let pinnedSet: Set<TaskRecord> = Set(pinned)              // dedup by content
let byId = Dictionary(uniqueKeysWithValues:
    tasks.map { ($0.id, $0) })                             // [String: TaskRecord]

XCTAssertEqual(before, after)                              // by content
```

Free `Equatable` and `Hashable` synthesis (which only fires for
structs/enums) makes all of this work without thought. With class
records:

- `Set<TaskRecord>` dedupes by *pointer* identity unless you
  hand-roll `==` and `hash(into:)`.
- `XCTAssertEqual(a, b)` asserts pointer equality unless
  overridden — silent footgun in tests.
- `JSONEncoder().encode(task)` requires hand-rolled `Codable`
  conformance (synthesis is structs-only).

All solvable with codegen-emitted boilerplate, but it's ~80 lines
per model that we currently get for free.

#### What you give up by picking structs

Honest cost list, no hand-waving:

- **No `TaskRecord.find(id:)`.** You write
  `TypedModel<TaskRecord>(doc: doc).find(id:)`. Usually cached as
  `let model = TypedModel<TaskRecord>(doc: doc)` at the top of a
  view — one extra line.
- **Reads are snapshots, not live bindings.** `model.find(id: "x")`
  returns a value captured at that moment. To pick up remote CRDT
  updates you re-`find` or use the wrapper's `subscribe { … }`.
  With a class plus `@Observable`, SwiftUI would re-render
  automatically when remote writes arrive. With structs you wire
  that yourself.
- **Explicit `model.update(...)`.** `task.title = "x"` mutates
  your local copy; you call `model.update(...)` to push it to the
  CRDT. More keystrokes — but **this is arguably a feature in a
  CRDT app**. CRDT writes propagate to other clients; making the
  cross-network step explicit is helpful, not annoying.

#### The actual reason: free vs. built

The struct wins (`@State` drafting, naked records, free
conformances) all use language features Swift gives you. The
class wins (`Contact.find`, live binding, identity-map semantics)
are *features we'd have to build* — an identity map keyed by id
per doc, observation plumbing per field, a detached-vs-attached
distinction with runtime guards, hand-rolled or codegen-emitted
conformances.

Picking structs cashes in on what Swift already provides; picking
classes asks us to rebuild a chunk of TS's BaseModel runtime in
exchange for the syntactic ergonomic. The current code ships only
the struct half. If we ever need TS-style live binding, the
defensible move is to *add* a class-based `LiveTaskRecord<T>`
wrapper alongside the struct (codegen emits both, app code picks
per use case) — not to flip the record itself to a class.

### Why does `query` route through untyped row dicts?

> **Q: When I look at the implementation, `dynamic.query(...)`
> returns `[[String: Any]]` — a list of untyped dicts — and the
> typed query path turns each row back into a `TaskRecord`. Why
> the round trip? Why can't `model.query()` hand me typed records
> directly?**

It does — *the user-facing API is typed*:

```swift
let urgent: [TaskRecord] = model.query(["priority": ["$gte": 5]])
```

You never touch a `[String: Any]` row in app code. The wrapper
returns `[TaskRecord]`. At the API level this is the same shape
as TS's `Contact.query(...)` returning `Contact[]`.

The dict-row pivot is *internal*, and it's there for the same
reason TS's BaseModel has it internally: **Y.Map isn't queryable**.
Y.Map is a CRDT key-value tree; it doesn't support filter / sort /
aggregate. To run something like `WHERE priority >= 5 ORDER BY
createdAt DESC LIMIT 20` efficiently, the runtime keeps a
synchronous SQLite mirror of every record. SQLite is what answers
queries. SQLite hands rows back as `[String: Any]` — that's just
the SQLite C API, there's no way to ask SQLite for a typed Swift
value.

So the pipeline:

1. `model.query(filter)` (typed)
2. → `dynamic.query(filter)` runs SQL on the SQLite mirror, gets
   back `[[String: Any]]`
3. → for each row, the wrapper materializes a `TaskRecord` and
   the result is `[TaskRecord]` (typed)

TS's `BaseModel.query` has the *same* internal pipeline. The
difference is only that TS hides it inside the class method while
Swift surfaces it through the wrapper layer.

> **Why is `dynamic.query` even visible to the public API?**
> Because the dynamic layer is schema-driven, not type-driven —
> it works for schemas discovered at runtime via `SchemaDiscovery`
> (no Swift type exists for those, so it can't return a typed
> array). For typed app code you use `TypedModel<T>.query` and
> never see the dict-row layer.

> **Implementation note (visible in [TypedModel.swift:84-92](../Sources/JsBaoClient/Schema/TypedModel.swift)).**
> Today the typed `query` path runs the SQL, then re-finds each
> row by id via `dynamic.find` — going back to the CRDT to
> materialize through the protocol-required `init?(record:)`. The
> codegen-emitted `init?(row:)` would let it materialize directly
> from the SQL row in one pass, skipping the CRDT re-read; we
> route through `find` instead because `init?(row:)` is
> codegen-only, not part of the `PrimitiveModel` protocol — so
> the typed-query path stays compatible with hand-rolled models.
> If the N+1 cost ever becomes a problem, lift `init?(row:)` into
> the protocol and switch to a one-pass cast. Pinned by
> `testInitRowFromDynamicQuery_includingStringset`.

## Why both `static let primitiveSchema` AND stored properties?

> **Q: I see `static let primitiveSchema` listing every field, AND
> `var name: String?` on the struct itself. Isn't that the same
> info twice?**

It is — same data, different audience.

| Audience | Reads from | Why |
|---|---|---|
| Swift compiler / your code | stored properties (`record.name`) | typecheck, autocomplete, IDE rename, refactor |
| Runtime (CRDT, SQLite mirror, validation, defaults, uniqueness, relationship resolver) | `static primitiveSchema` | needs to enumerate fields and know their flags to build CRDT writes, SQL columns, validation rules |

In TS, the runtime side reads decorators / registered metadata via
`BaseModel`'s static registry — that registry plays the role of
`primitiveSchema`. The compile-time side reads `ContactAttrs`. The
duplication is there too, just less visible because the interface
declaration has zero runtime cost.

Swift could in principle reflect over the struct via `Mirror` to
recover the schema at runtime, but `Mirror` doesn't surface flags
like `unique`, `indexed`, `maxLength`, defaults, or relationships
— those don't live on the property type. Keeping the schema literal
in the file is more honest, and the codegen is what stops the two
representations from drifting apart.

## Why isn't the Swift output as light as TS?

Three constraints stack up:

1. **Swift structs can't inherit.** TS's
   `class Contact extends BaseModelImpl {}` gets every BaseModel
   method (`save`, `find`, `query`, prototype proxy for fields)
   for free via single inheritance. Swift structs only *conform to*
   protocols. Protocols can carry default implementations for
   stateless behavior, but they can't carry stored state — there's
   no way for a protocol to say "and I'll hold a reference to your
   CRDT doc on every conformer". So there's no equivalent of
   "extend a base class and inherit a 600-line CRUD surface".
2. **Swift type-safety needs real stored properties.** TS's
   "interface for the field shape + empty class" works because
   `interface` is a compile-time-only construct — at runtime,
   `contact.name = "x"` triggers a prototype getter/setter on
   `BaseModelImpl` that proxies the write into the CRDT. Swift has
   nothing equivalent to interface declaration merging, and
   `Mirror`-based reflection isn't a substitute (no setter, no
   per-field flags). For `task.title` to even compile typed, the
   struct needs an actual `var title: String?` stored property.
3. **Cross-file synthesis is limited.** Swift will auto-synthesize
   `Equatable` / `Hashable` / `Codable` only when the conformance
   declaration lives in the *same file* as the type declaration.
   Codegen putting `: PrimitiveModel, Equatable, Hashable, Codable`
   on the struct buys you all three for free. Putting them anywhere
   else (e.g., in an extension file) means hand-rolling them — about
   80 lines of mechanical boilerplate per model.

Given those three, the four init/serialize methods are just the
mechanical bridge between the typed Swift struct and the dynamic
runtime layer:

| Generated method | Why it exists |
|---|---|
| Designated `init(...)` | Swift requires an explicit `init` for non-default-constructible structs; matches the demo's hand-written shape (id-first, optional fields default to `nil`). |
| `init?(record:)` | "Read this CRDT-backed `PrimitiveRecord` into a typed value" — `nil` if a required field is missing. Used by `TypedModel.find` / `findAll`. |
| `init?(row:)` | "Read this SQLite-mirror row dict into a typed value" — used by `dynamic.query(...)` for indexed-filter / pagination paths. Different from `init?(record:)` because the SQLite row is `[String: Any]`, not `PrimitiveRecord`. The two readers have separate cast rules — stringsets come back as `[String]` from SQLite, as `Set<String>` from PrimitiveRecord. |
| `primitiveValues()` | Project the typed value back into a `[String: PrimitiveValue]` so the dynamic write path can encode it onto the doc. |

**Could it ever get lighter?** Two paths, neither on this PR's
runway:

- **Swift macros (5.9+).** Write `@PrimitiveModel struct TaskRecord
  { var id: String; var title: String? }` and have a macro inject
  the schema literal + the four serialize methods at compile time.
  This is the closest Swift gets to TS-level lightness. Cost: macros
  need their own SwiftPM target with its own toolchain, and macro
  errors land at a different layer than typecheck errors. Open
  option, would replace the current build-tool plugin.
- **Reflection-driven runtime layer.** Build the schema and the
  serialization paths from `Mirror` at first use. Loses static
  guarantees (typo in a field flag won't fail compile), can't
  capture `unique` / `indexed` / defaults at all, and *still*
  requires real stored properties. Net negative.

Neither path closes the whole gap to TS-level lightness without a
language-level feature TS can't natively express either — TS's
trick is the interface+prototype combo, not lightness for its own
sake.

## How it works under the hood

```
schema.toml ──► swift-bao-codegen ──► <Model>Record.swift ──► your app
              │                     │
              │ TomlParser          │ SwiftEmitter
              │   ├── ParsedSchema  │   ├── struct decl + storedProperties
              │   ├── ParsedField   │   ├── designated init
              │   └── …             │   ├── init?(record:)  ← reads PrimitiveRecord
              │                     │   ├── init?(row:)     ← reads SQLite row dict
              │                     │   └── primitiveValues()
              │                     │
              └── one .swift file per [models.X] table

At runtime:
                                                ┌─ TypedModel<TaskRecord>(doc:)
TaskRecord ──► PrimitiveModel protocol ────────►│   wraps DynamicModel
              (modelName, primitiveSchema, id,  │   surfaces typed find/create/update/query
               init?(record:), primitiveValues)│
                                                └─ DynamicModel writes Y.Map + maintains
                                                   in-memory SQLite mirror
```

**The five stages:**

1. **`TomlParser`** ([Sources/SwiftBaoCodegen/TomlParser.swift](../Sources/SwiftBaoCodegen/TomlParser.swift)) — TOML → in-memory `ParsedSchema` IR. Two-pass: pass 1 collects fields + uniques + resolves `class_name`; pass 2 walks relationships now that all model names are known. Validation rules mirror the runtime layer's `TomlSchemaLoader` so a TOML that passes codegen also loads at runtime.

2. **`SwiftEmitter`** ([Sources/SwiftBaoCodegen/SwiftEmitter.swift](../Sources/SwiftBaoCodegen/SwiftEmitter.swift)) — pure string-template pass over `ParsedSchema`. Emits one `.swift` file per model with the static schema literal, stored properties, three inits (designated, `init?(record:)`, `init?(row:)`), and `primitiveValues()`.

3. **`main.swift`** ([Sources/SwiftBaoCodegen/main.swift](../Sources/SwiftBaoCodegen/main.swift)) — CLI driver. Reads the TOML, runs the parser, runs the emitter, **detects Swift-name collisions** (two models resolving to the same swiftName fail-fast with both names), writes only when contents change (incremental-build-friendly), **sweeps stale generated files** that no longer correspond to a model in the TOML — but only deletes files starting with the `// Generated by swift-bao-codegen` banner, so user-authored neighbors survive.

4. **`JsBaoCodegenPlugin`** ([Plugins/JsBaoCodegenPlugin/JsBaoCodegenPlugin.swift](../Plugins/JsBaoCodegenPlugin/JsBaoCodegenPlugin.swift)) — SwiftPM build-tool plugin. Auto-runs `swift-bao-codegen` on every `swift build`. Has to *predict* the generated filenames upfront (SwiftPM contract: outputs declared before the tool runs) — does so via a hand-rolled mini-TOML scanner that doesn't depend on TOMLKit (keeps the plugin's build closure light). Drift between scanner and parser surfaces as "missing output" build errors; pinned by [`PluginScannerTests`](../Tests/SwiftBaoCodegenTests/PluginScannerTests.swift).

5. **Runtime layer** ([Sources/JsBaoClient/Schema/](../Sources/JsBaoClient/Schema/)) — `TypedModel<T>(doc:)` wraps a `DynamicModel` over a Y-CRDT `YDocument`. Local writes go through `T.primitiveValues()` and are reflected synchronously into a per-model SQLite mirror (the query engine). Remote writes (over the WebSocket) propagate via yrs observers and dispatch onto an observer-drain queue that re-reads each record into the SQLite mirror. Queries call `awaitObserverDrain()` first so SELECTs always see the latest state.

The on-doc wire format for codegen-emitted records is pinned by
[`CodegenWireFormatTests`](../Tests/JsBaoClientTests/Schema/CodegenWireFormatTests.swift)
(scalar shapes per type) and
[`CrossPlatformCodegenTests`](../Tests/JsBaoClientTests/CrossPlatform/CrossPlatformCodegenTests.swift)
(JS reads + JS writes verifying byte-equivalence with js-bao).

## Schema sources — when to use what

There are several ways to get a `PrimitiveSchema` into the runtime.
**Codegen is the canonical path.** The other paths exist for narrower
use cases; if your TOML is checked into your source tree, you want
codegen.

### 1. Codegen (canonical, recommended)

Your TOML lives in your source tree; `swift-bao-codegen` emits one
Swift file per model at build time. Use the generated structs via
`TypedModel<TaskRecord>(doc:)`.

- Type-safe field access (`task.title: String`, not `record["title"]?.asString`)
- Compile-time validation of required fields
- IDE autocomplete + safe rename
- Single source of truth (TOML)

This is what every example in this doc uses. See [Two ways to use it](#two-ways-to-use-it).

### 2. `SchemaDiscovery` (introspecting docs you don't own)

[`SchemaDiscovery`](../Sources/JsBaoClient/Schema/SchemaDiscovery.swift) reads
schemas back out of the doc's `_meta_<modelName>` Y.Maps. Use this when:

- You're building a tool that opens *arbitrary* Primitive docs (an
  inspector, debugger, or multi-tenant explorer)
- The doc was already written to by another client (so the `_meta_*`
  maps exist)
- You don't have the TOML at build time

Hand the resulting `PrimitiveSchema` to `DynamicModel(doc:schema:)`.
You won't get a typed wrapper — access is via `PrimitiveRecord` (dict-
like). This is the right answer for cross-client introspection.

### 3. Direct `PrimitiveSchema(...)` construction (advanced)

[`PrimitiveSchema`](../Sources/JsBaoClient/Schema/PrimitiveSchema.swift) has a
public init. If you're building a no-code app, plugin system, or
anything where the schema is constructed programmatically at runtime,
build the value directly in Swift — no TOML needed.

### 4. Hand-rolled struct (manual codegen)

The `PrimitiveModel` protocol is public, and the codegen-emitted
shape is mechanical. You can write a conforming struct yourself and
plug it into `TypedModel<T>(doc:)` exactly like a codegen-emitted
one. See [Manual codegen — write the struct by hand](#manual-codegen--write-the-struct-by-hand)
for a worked example. Use this only when wiring up the build-tool
plugin would cost more than the ~60 lines of mechanical projection.

### 5. `TomlSchemaLoader` (supported, but codegen is preferred)

> **Codegen is the preferred path.** `TomlSchemaLoader` is fully
> supported public API and isn't going anywhere, but if your schema
> is known at build time you'll get a better experience (type-safe
> structs, no runtime parse cost) by using `swift-bao-codegen`.

[`TomlSchemaLoader`](../Sources/JsBaoClient/Schema/TomlSchemaLoader.swift) parses a
TOML string at runtime into `[PrimitiveSchema]`, matching js-bao's
`loadSchemaFromTomlString`. Reach for it when:

- You're loading a schema you don't own at build time (e.g. a tool
  that inspects user-supplied TOML).
- You're writing tests, demos, or scripts where the build-time plugin
  would be friction.
- You need cross-language parity with a JS caller that's also using
  the runtime loader.

In production app code where the schema is known up front, codegen
is preferred — it gives you typed structs, removes the runtime parse
cost, and removes a class of "did I sync these copies?" bugs.

There is some duplication between `TomlSchemaLoader` and
`swift-bao-codegen`'s `TomlParser` (two parsers must stay in sync).
That duplication is intentional: the runtime loader covers cases
where build-time codegen can't, and the cross-platform TOML parity
test enforces both walk the same shape.

| Path | Use when | Type-safe? | Build-time? |
|------|----------|-----------|-------------|
| Codegen | Schema known at build time (preferred for app code) | ✅ | ✅ |
| `SchemaDiscovery` | Inspecting docs whose schema is in `_meta_*` | ❌ (dict access) | runtime |
| `PrimitiveSchema(...)` | Programmatic / dynamic schemas in code | ❌ (dict access) | runtime |
| Hand-rolled struct | One-off model where the build plugin is overkill | ✅ | build (your hands) |
| `TomlSchemaLoader` | Loading TOML you don't own at build time | ❌ (dict access) | runtime |

## Two ways to use it

### A. SwiftPM plugin — auto-runs on every build

This is the path you want for `swift run` / `swift build` / Xcode
(via SPM-managed dependency).

```swift
// Package.swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "JsBaoClient", package: "JsBaoClient"),
    ],
    plugins: [
        .plugin(name: "JsBaoCodegenPlugin", package: "JsBaoClient"),
    ]
)
```

Drop a `schema.toml` into your target's source tree:

```
Sources/MyApp/
├── ...
└── Models/
    └── schema.toml
```

The plugin auto-detects any file whose name ends in `schema.toml` and
runs codegen on each. Generated `.swift` files land in the plugin's
work directory (`.build/plugins/.../GeneratedModels/`) and are picked
up by the compiler automatically — they don't need to be committed.

> **Plugin defaults are not configurable.** The plugin invokes the
> codegen tool with `--input` and `--output` only. Generated types
> always have `internal` access, the import is always `JsBaoClient`,
> and the file-name suffix is always `Record` (also hardcoded in the
> plugin's output prediction). If you need `--access public`, a
> different `--module-import`, or a non-`Record` suffix, use the
> standalone CLI instead.

### B. Standalone CLI — for Xcode projects without SPM plugins, custom toolchains, CI generation, etc.

```sh
swift run swift-bao-codegen \
  --input  Sources/MyApp/Models/schema.toml \
  --output Sources/MyApp/Models/Generated
```

Common options:

| Flag | Default | Notes |
|------|---------|-------|
| `--input <file>` | — | The TOML file (required). |
| `--output <dir>` | — | Output directory (required). One `.swift` per model. |
| `--access`       | `internal` | `internal` or `public`. |
| `--module-import` | `JsBaoClient` | Module that exports `PrimitiveModel`, `PrimitiveSchema`, etc. |
| `--name-suffix`  | `Record` | Default suffix appended to PascalCase(model name). |

### Xcode "Run Script" build phase

For non-SPM Xcode projects, add a Run Script build phase that runs
*before* "Compile Sources":

```sh
"$BUILT_PRODUCTS_DIR/swift-bao-codegen" \
  --input  "$SRCROOT/MyApp/Models/schema.toml" \
  --output "$SRCROOT/MyApp/Models/Generated"
```

Then commit `Generated/` (it changes only when the TOML changes) and
add the directory to the Compile Sources phase.

## Naming

Default Swift type name: `<PascalCase(modelName)>Record`.

| TOML model name | Default Swift type |
|-----------------|--------------------|
| `tasks` | `TasksRecord` |
| `liveUpdatesState` | `LiveUpdatesStateRecord` |
| `user_profile` | `UserProfileRecord` |

To override per-model (recommended when the table name doesn't match
the singular name you want for a Swift struct), set `class_name` at
the top of the model table — same key js-bao reads at runtime, no
swift-specific TOML namespace:

```toml
[models.tasks]
class_name = "TaskRecord"

[models.tasks.fields.id]
type = "id"
# ...
```

To change the default suffix project-wide, pass `--name-suffix` (or set
it via the plugin — see the plugin source for how to forward args).

### Identifier rules

The `class_name` override must be a valid Swift identifier:
- Must match `^[A-Za-z_][A-Za-z0-9_]*$` (no spaces, no leading digits)
- Cannot be a reserved Swift keyword (`let`, `class`, `struct`, etc.)

Both rules are enforced in `TomlParser.resolveSwiftName` and surface
as `CodegenError.invalidClassName` from `swift-bao-codegen` so the
error names the offending TOML model rather than landing on a confusing
Swift compile error in generated code.

### Field names and reserved Swift keywords

Field names that happen to be Swift keywords (`default`, `where`,
`class`, `init`, `var`, `let`, `for`, etc.) are wrapped in backticks
in every generated Swift identifier site:
- The stored property declaration
- The designated init parameter list and body
- `init?(record:)` and `init?(row:)` bodies (LHS only — the dict key
  uses the raw TOML name)
- `primitiveValues()` `if let` shorthand and value reference

The wire-side (Y.Map keys, dict literals) keeps the raw TOML name —
backticks are a Swift identifier concern, not a wire-format concern.
See `SwiftEmitterTests.testEverySwiftKeywordAsFieldName_isBacktickEscapedEverywhere`
for the comprehensive sweep.

### Unicode model and field names

TOML keys with non-ASCII characters MUST be quoted (TOML spec — bare
keys are ASCII only). Quoted unicode keys flow through the emitter
unchanged and land on the generated struct as Swift identifiers
(Swift accepts Unicode L*/Nl categories):

```toml
[models."café"]                    # bare `[models.café]` is rejected
[models."café".fields."naïve"]
type = "string"
```

Generated:
```swift
internal struct CaféRecord: PrimitiveModel {
    internal var naïve: String?
    // ...
}
```

## Generated shape

For each `[models.X]` table, one Swift file:

```swift
// Generated by swift-bao-codegen — DO NOT EDIT.
// Source: schema.toml (model: tasks)

import Foundation
import JsBaoClient

internal struct TaskRecord: PrimitiveModel, Equatable, Hashable, Codable {
    internal static let modelName = "tasks"
    internal static let primitiveSchema = PrimitiveSchema(
        name: "tasks",
        fields: [
            "id":       FieldDescriptor(type: .id),
            "title":    FieldDescriptor(type: .string, required: true),
            "priority": FieldDescriptor(type: .number, indexed: true),
            // ...
        ]
    )

    internal var id: String
    internal var title: String
    internal var priority: Double?
    // ...

    internal init(/* ... */) { /* ... */ }
    internal init?(record: PrimitiveRecord) { /* ... */ }
    internal init?(row: [String: Any]) { /* ... */ }

    internal func primitiveValues() -> [String: PrimitiveValue] { /* ... */ }
}
```

### Field type mapping

| TOML type | Swift type | Required-true override |
|-----------|------------|------------------------|
| `string`  | `String?`  | `String` |
| `number`  | `Double?`  | `Double` |
| `boolean` | `Bool?`    | `Bool` |
| `date`    | `String?`  | `String` (ISO-8601, mirrors `record["x"]?.asDateString`) |
| `id`      | `String`   | always non-optional |
| `stringset` | `Set<String>?` | `Set<String>` |

### Conformances are auto-emitted

Generated structs declare `: PrimitiveModel, Equatable, Hashable, Codable`
on the struct itself. Swift's compiler synthesizes `==`, `hash(into:)`,
and `init(from:)` / `encode(to:)` automatically *in the generated
file* — synthesis only fires same-file. **You don't need to hand-roll
any of these.**

```swift
let a = TaskRecord(id: "x", title: "y")
let b = TaskRecord(id: "x", title: "y")
let same = (a == b)              // Equatable
let set: Set<TaskRecord> = [a]   // Hashable
let json = try JSONEncoder().encode(a)              // Codable
let decoded = try JSONDecoder().decode(TaskRecord.self, from: json)
```

This works for every codegen-supported field type (`String`, `Double`,
`Bool`, `Set<String>`, plus optionals). Reserved-keyword fields
(`default`, `where`) round-trip through Codable too — Swift's
`CodingKeys` synthesis handles backtick escapes automatically when
the conformance lives in the same file as the type.

## Adding helpers (free functions)

> **Recommended over Swift extensions on the generated struct.**
> Swift extensions still work — the language allows them on any
> type — but match the TS codegen's pattern: write helpers as
> standalone free functions instead of reaching back into the
> generated type's namespace.

The TS codegen does not encourage users to extend the generated
`Contact` class. If you want a derived value, you write a helper:

```ts
function displayTitle(contact: Contact): string {
  return contact.name?.toUpperCase() ?? `(${contact.id})`;
}
```

Match that in Swift:

```swift
// Helpers.swift (hand-written, anywhere in your target)
import Foundation

func displayTitle(_ record: TaskRecord) -> String {
    record.title.uppercased()
}

func placeholderTask(named name: String) -> TaskRecord {
    TaskRecord(id: "placeholder-\(name)", title: name)
}

func sharesTitle(_ a: TaskRecord, _ b: TaskRecord) -> Bool {
    a.title == b.title
}
```

That's the recommended pattern. No extension on the generated
struct, no module-level monkey-patching of the typed surface.

If you're writing helpers that work over *any* `PrimitiveModel`,
make them generic:

```swift
func describe<M: PrimitiveModel>(_ value: M) -> String {
    "\(M.modelName)#\(value.id)"
}
```

These compile against any codegen-emitted record exactly because the
record conforms to `PrimitiveModel`.

The codegen doesn't care where these helper files live — they can
sit next to the generated output, in a sibling directory, anywhere
your target compiles. The codegen sweep only deletes files in the
output directory whose first line is the
`// Generated by swift-bao-codegen` banner; your `Helpers.swift`
(or anything else without that banner) is safe.

> **Why drop Swift extensions on the generated type?** Extensions
> grow a namespace ambiguity that nobody wants on shared model
> code: a method on `TaskRecord` *could* come from codegen, *could*
> come from your extension, *could* come from a third extension
> three folders over. Free functions stay clearly user code, the
> way TS's helper functions do, and don't require you to think
> about whether the codegen will overwrite them on the next build.

### Adding a *conformance* (not a method)

If you really need to add a custom protocol conformance — say,
`TaskRecord: Displayable` — the cleanest shape is to define
`Displayable` with a default implementation that keys off
`PrimitiveModel`, then mark the conformance on each opt-in type
with one line:

```swift
protocol Displayable {
    var displayString: String { get }
}

extension Displayable where Self: PrimitiveModel {
    var displayString: String { "\(Self.modelName)#\(id)" }
}

// Single-line opt-in:
extension TaskRecord: Displayable {}
```

That's "extension" in the syntactic sense — you can't avoid the
keyword to declare a conformance — but it adds zero new methods to
`TaskRecord`'s namespace. Behavior lives on the protocol, not on
the type.

## Manual codegen — write the struct by hand

Codegen is the canonical path for build-time-known schemas, but
nothing about `PrimitiveModel` requires you to use the tool. The
protocol is public; anyone can hand-roll a struct that conforms
to it. The codegen output is mechanical — write the equivalent
yourself when wiring up the build-tool plugin would cost more
than ~60 lines of mechanical projection (one-off models, tests,
fixtures, single-page demos).

Minimum viable hand-rolled model:

```swift
import JsBaoClient

struct TaskRecord: PrimitiveModel {
    static let modelName = "tasks"
    static let primitiveSchema = PrimitiveSchema(
        name: "tasks",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
        ]
    )

    var id: String
    var title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init?(record: PrimitiveRecord) {
        guard let title = record["title"]?.asString else { return nil }
        self.id = record.id
        self.title = title
    }

    func primitiveValues() -> [String: PrimitiveValue] {
        ["title": .string(title)]
    }
}
```

That's the lower bound. Plug it into `TypedModel<TaskRecord>(doc:)`
exactly like a codegen-emitted struct — no registration step, no
plugin. Add `init?(row:)` if you want to read through
`dynamic.query(...)`'s SQLite path. Add `, Equatable, Hashable,
Codable` to the struct decl if you want value equality and JSON
for free (synthesis fires because the conformances live in the
same file as the type).

The trade-off is the obvious one: no single source of truth, no
free conformance synthesis if you split the file, and you're
re-implementing the same projection codegen would have generated.
The Primitive demo apps' early models predate codegen and were
all hand-rolled this way; they look identical in shape to what
the codegen produces, which is the proof that the tool is a pure
mechanical step.

## Moving from runtime TOML loading to codegen

If you previously bundled `schema.toml` as a resource and used a
`DemoSchema`-style cache (loading at process start), or called
`TomlSchemaLoader.load(...)` directly in app code, switching to
codegen lets you drop:

- the `.process("Models/schema.toml")` resource declaration in
  `Package.swift`
- the `INFOPLIST` / `project.yml` line copying the TOML into the app
  bundle
- the `DemoSchema` cache file (or any equivalent runtime-load wrapper)
- any `DemoSchema.preload()` / `TomlSchemaLoader.load(...)` calls
  at app start

The TOML is still the source of truth — it's just consumed at *build*
time. Switch each call site that read schemas via `TomlSchemaLoader`
to the codegen-emitted typed wrapper:

```swift
// Before
let schemas = try TomlSchemaLoader.load(from: bundleURL)
let model = DynamicModel(doc: doc, schema: schemas[0])

// After (codegen-emitted TaskRecord)
let model = TypedModel<TaskRecord>(doc: doc)
```

If you have a runtime-loading need that codegen doesn't cover
(loading TOML you don't own, schemas downloaded at runtime, tooling),
`TomlSchemaLoader` is fully supported — use it. For inspecting docs
written by other clients, `SchemaDiscovery` is usually a better fit
than re-parsing TOML; see the
[Schema sources](#schema-sources--when-to-use-what) section above.

## Schema evolution playbook

When your TOML changes shape between releases, here's what each kind
of change does to existing records — and what to do about it. Each
behavior is pinned by a test in
[`CodegenSchemaEvolutionTests.swift`](../Tests/JsBaoClientTests/Schema/CodegenSchemaEvolutionTests.swift).

| Change | Behavior on existing records | Migration needed? |
|---|---|---|
| **Add an optional field** | Reads back as `nil` | No |
| **Remove a field** | Data stays in Y.Map; `record[fieldName]` still reads it; never auto-overwritten | No (orphan is benign; can be cleaned up at leisure) |
| **Rename a field** | Old data orphans at old key; new field reads `nil` | Yes — read old via `record[oldName]`, write new via `update(values: [newName: ...])`, optionally delete old |
| **Add `required: true` to existing optional** | Typed `init?(record:)` returns `nil`; dynamic layer still surfaces the record (required is enforced at write, not read) | Yes — backfill the field on all existing records before deploying v2 |
| **Change a field's type** | Old wire bytes don't match new type → reads back as `nil`; new writes round-trip cleanly | Yes — read old via `record[name]?.asOldType`, write new via `update(values: [name: .newType(...)])` |

Key insight: **`PrimitiveRecord[fieldName]` reads from the raw Y.Map
regardless of the current schema's declared fields.** This is
intentional — it's what makes `read old, write new, delete old`
migrations possible without dropping into the raw `YrsMap` layer.

Concrete migration recipe for renaming `oldName` → `newName`:

```swift
let model = TypedModel<MyRecord>(doc: doc)
let dyn = model.dynamic
for record in dyn.findAll() {
    if let oldValue = record["oldName"]?.asString {
        try dyn.update(id: record.id, values: [
            "newName": .string(oldValue),
        ])
        // Optional: explicitly clear the old field. The dynamic
        // update with [oldName: .string("")] won't remove the key —
        // you'd need a raw YrsMap.remove call. For most schemas the
        // orphan is harmless; clean up only if you're space-
        // sensitive.
    }
}
```

The `CodegenSchemaEvolutionTests.swift` tests pin each behavior with
an executable example.

## Gotchas

### Non-finite numbers (NaN, Infinity) are silently dropped

`PrimitiveValue.encodeNumber` returns `nil` for any non-finite double
(NaN, ±Infinity). Because `nil` skips the field at the write call
sites — `encodedForYrs()`, `UniqueConstraintEnforcement.stringify`,
`SchemaSync.setScalar` — passing a non-finite number produces a
record where that field is **absent**, not a record with a sentinel
value and not a write error.

If your application needs a strict signal instead of silent elision,
validate at the call site with `Double.isFinite` before constructing
the `PrimitiveValue`.

Pinned at the encoder level in
[`CodegenEdgeCaseTests.testNumber_NaN_encoderRefusesNonFinite`](../Tests/JsBaoClientTests/Schema/CodegenEdgeCaseTests.swift)
and `testNumber_infinity_encoderRefusesNonFinite`.

## Testing

The codegen has two test suites in this repo, plus an on-device
"gauntlet" page in `primitive-app-demo` that runs the same shape
through a real SwiftUI app target.

### `CodegenAcceptance` (golden-file pattern)

Files under [`Tests/JsBaoClientTests/Schema/CodegenAcceptance/`](../Tests/JsBaoClientTests/Schema/CodegenAcceptance/):

```
fixture.toml                       ← input schema (TaskRecord + 4 gauntlet models)
Generated/                         ← committed codegen output
  ├── TaskRecord.swift
  ├── CrashTestRecord.swift
  ├── UserProfileRecord.swift
  ├── BareBonesRecord.swift
  └── RelTestRecord.swift
Helpers.swift                      ← hand-written free-function helpers (recommended pattern)
```

`Generated/` is **committed** and compiled into the test target as
regular sources. The `JsBaoCodegenPlugin` is **not** attached here on
purpose — committing the goldens means an emitter change shows up as
a reviewable diff in `Generated/`. To re-roll after editing the
fixture or the emitter:

```sh
swift run swift-bao-codegen \
  --input  Tests/JsBaoClientTests/Schema/CodegenAcceptance/fixture.toml \
  --output Tests/JsBaoClientTests/Schema/CodegenAcceptance/Generated
```

A second guarantee falls out of this layout: if `JsBaoClient`'s public
API changes in a way that breaks generated code, the test target
fails to *compile* — independent of any test method running.

### `CodegenAcceptanceTests` — minimal end-to-end

[`CodegenAcceptanceTests.swift`](../Tests/JsBaoClientTests/Schema/CodegenAcceptanceTests.swift) — 3 tests on the original
`TaskRecord` golden:

1. The generated `primitiveSchema` literal matches the TOML fixture
   field set + flags.
2. A `TaskRecord` round-trips through `TypedModel<TaskRecord>` against
   a real `YDocument()` (proves codegen-emitted `init?(record:)` and
   `primitiveValues()` agree on the wire format).
3. `primitiveValues()` omits unset optional fields — the dynamic layer
   relies on this so that "field not present" reads as nil rather than
   "field is empty string".

### `CodegenGauntletTests` — every TOML knob, every emitter path

[`CodegenGauntletTests.swift`](../Tests/JsBaoClientTests/Schema/CodegenGauntletTests.swift). Run with:

```sh
swift test --filter CodegenGauntletTests
```

The fixture has four extra models so each codegen surface has a
fixture exercising it:

| Model | Why it's there |
|---|---|
| `crashTest` → `CrashTestRecord` | Kitchen sink: optional + required `stringset`, `unique = true`, `max_length`, `max_count`, three `default` values (string/number/bool), `indexed` numeric, **two reserved-keyword field names** (`default`, `where`), a compound `unique_constraints` block on `(boundedName, score)` chosen so it doesn't overlap the single-field unique on `email`. |
| `user_profile` → `UserProfileRecord` | snake_case TOML name → default-rule PascalCase Swift type. No `class_name` override, so the default name path is exercised. |
| `barebones` → `BareBonesRecord` | Only `id`. Pins the codegen edge case where `primitiveValues()` returns `[:]`. |
| `relTest` → `RelTestRecord` | All three relationship kinds (`refersTo` / `hasMany` / `hasManyThrough`) folded into one `relationships:` block. |

What each test pins, by feature:

#### Static schema literal

| Test | Pins |
|---|---|
| `testCrashTestSchemaLiteral` | every `FieldDescriptor` flag the emitter touches: `type`, `required`, `unique`, `indexed`, `maxLength`, `maxCount`, `default: .scalar(...)` for string/number/boolean. Compound constraint `name_score_combo` shows up under `primitiveSchema.constraints` with the right field list. |
| `testRelTestRelationshipsLiteral` | `refersTo` carries `relatedIdField`; `hasMany` carries `orderByField`/`orderDirection`; `hasManyThrough` carries `joinModel`/`joinModelLocalField`/`joinModelRelatedField`. |
| `testSnakeCaseModelNameMapsToPascalCaseSwiftType` | the literal Swift-type token (`UserProfileRecord`) compiling at all is the proof that `Naming.pascalCase` produced it. |
| `testEmptyFieldsModel_primitiveValuesIsEmpty` | the `[:]` literal path. |
| `testReservedKeywordFields_usableAsProperties` | backtick escapes on property *reads* and on init *labels* (Swift treats them differently). |

#### `init?(record:)` round-trips

The path used by `TypedModel.find` / `findAll`. Records come off the
Y-CRDT as `PrimitiveRecord`, projected via the codegen-emitted
failable init.

| Test | Pins |
|---|---|
| `testStringsetRoundTrip_requiredAndOptional` | `Set<String>` and `Set<String>?` round-trip byte-equal through `init?(record:)` |
| `testStringsetRoundTrip_emptySetReadsBackEmptyOrNil` | empty stringsets don't poison the round-trip |
| `testReservedKeywordFields_roundTripThroughDoc` | reads `record["default"]?.asString` correctly populate the backticked Swift property |
| `testInitFailsWhenRequiredFieldMissing_returnsNil` | schema-drift: write a valid record, clear the required field via subscript, typed `find` degrades to nil while the dynamic record stays readable |

#### `init?(row:)` round-trips

The path used by `dynamic.query` → `compactMap(T.init(row:))` and by
real demo pages that drive `BaoDataLoader`. Rows come off SQLite as
`[String: Any]`.

| Test | Pins |
|---|---|
| `testInitRowFromDynamicQuery_includingStringset` | the spicy bit — `BaoModelQueryEngine.populateStringsetsFiltered` writes stringset columns back as `[String]`, so a naive `as? Set<String>` cast in the codegen would silently drop every row. The emitter now writes `(row[key] as? [String]).map(Set.init)`. **This test is what caught the original bug.** |

#### Validation & uniqueness

| Test | Pins |
|---|---|
| `testStringsetMaxCountEnforced` | writing 6 items into a `max_count = 5` field throws `FieldValidationError.stringsetMaxCountExceeded` |
| `testSingleFieldUniqueViolation_email` | two creates with the same email throws `UniqueConstraintViolationError` |
| `testCompoundUniqueViolation_boundedNameAndScore` | two creates with the same `(boundedName, score)` tuple throws even when the single-field-unique fields differ |

#### Runtime smoke through codegen-emitted models

Codegen output composing with the runtime query engine. Uses
`CrashTestRecord` so we're not reusing TaskRecord's fixture data.

| Test | Pins |
|---|---|
| `testFilterGteOnIndexedScore` | `["score": ["$gte": 50]]` — proves the `indexed: true` flag actually drives the SQLite-side index, and that filter operators work on codegen-emitted models |
| `testFilterOrAndContainsText` | `$or` of `$containsText` and `$gte` — exact-set membership assertion |
| `testMultiFieldSortOrder` | `sortOrder: [("score", -1), ("id", 1)]` returns rows in the right order |
| `testAggregateCountByActiveGroup` | aggregate `count` group-by on a `Bool` field; tolerates SQLite returning the bool column as `Int` 0/1 |
| `testCursorPagination_returnsNextCursor` | `queryPaged` returns a non-nil `nextCursor` on the first page when more rows exist |

#### Codegen-emitted conformances (Equatable / Hashable / Codable)

The codegen emits `Equatable, Hashable, Codable` directly on the
struct so Swift's compiler synthesizes the impls in the same file as
the type. (Synthesis only fires same-file — this is exactly why
codegen does it instead of leaving the user to hand-roll it.)

| Test | Pins |
|---|---|
| `testEquatable_isAutoSynthesizedOnGeneratedStruct` | `==` works out of the box on a codegen-emitted struct |
| `testHashable_letsGeneratedStructsLiveInASet` | `Set<TaskRecord>` deduplicates by content |
| `testCodable_jsonRoundTripsIncludingReservedKeywordFields` | `JSONEncoder` / `JSONDecoder` round-trips a `CrashTestRecord` whose fields include `default` and `where` (`CodingKeys` synthesis handles backtick escapes) |

#### Helpers as free functions (recommended over extensions)

Pins the recommended pattern from
[Adding helpers (free functions)](#adding-helpers-free-functions).
Helpers live in `Helpers.swift` next to the codegen output (not inside
`Generated/`).

| Test | Pins |
|---|---|
| `testHelper_computedDisplayTitle` | a free function reads codegen-emitted optional fields with id fallback (the "computed display value" pattern) |
| `testHelper_factoryStylePlaceholder` | a free factory function builds a record by funneling into the codegen designated init |
| `testHelper_genericOverPrimitiveModel` | a `<M: PrimitiveModel>` generic free function compiles against a codegen-emitted struct, exercising the protocol's static + instance requirements |

#### Update path & default materialization

| Test | Pins |
|---|---|
| `testUpdatePreservesUnchangedFields` | `dynamic.update(id:values:)` writes only the fields it's handed; the codegen-emitted `init?(record:)` sees the post-update state correctly |
| `testFieldDescriptorDefaultMaterializesAtCreate` | the codegen-emitted `default: .scalar(...)` literal is what the runtime's create path reads when filling in unsupplied fields. (`FieldValidationTests` cover the runtime side for hand-written schemas; this closes the codegen→runtime loop.) |

#### Other

| Test | Pins |
|---|---|
| `testEmptyFieldsModel_typedCRUD` | `BareBonesRecord(id:)` round-trips through `TypedModel<BareBonesRecord>` |
| `testRelTestRecord_typedCRUD` | a model carrying `relationships:` literal still compiles and CRUDs cleanly |
| `testStaticMetadata` (`testCrashTestSchemaLiteral`'s prelude) | `modelName` of every model matches the TOML |

### Other codegen-related test files

Beyond `CodegenGauntletTests`, the following targeted suites cover
narrower contracts of the codegen pipeline:

| File | Tests | What it covers |
|---|---|---|
| [`CodegenWireFormatTests.swift`](../Tests/JsBaoClientTests/Schema/CodegenWireFormatTests.swift) | 11 | Pins the **on-doc wire format** that codegen-emitted `primitiveValues()` produces — JSON-quoting on strings, bare `true`/`false` on booleans, integer-valued doubles emit without `.0`, stringset nested-Y.Map shape, the `id` mirror inside the record map for cross-client identity, escape rules for `"` / `\n`, raw unicode pass-through. Catches drift in `PrimitiveValue.encodedForYrs()` or the runtime stamp path. |
| [`CodegenEdgeCaseTests.swift`](../Tests/JsBaoClientTests/Schema/CodegenEdgeCaseTests.swift) | 21 | Boundaries of each field type: ISO date variants (Z suffix, fractional seconds, ±tz offset, date-only); number edges (zero, negative, very large, very precise, and **the NaN/Infinity known bug pinned at the encoder level**); stringset edges (single member, embedded quotes/newlines, emoji, empty-string member, 10KB member, full max_count). |
| [`CodegenSchemaEvolutionTests.swift`](../Tests/JsBaoClientTests/Schema/CodegenSchemaEvolutionTests.swift) | 7 | What happens when the TOML changes between releases — see [Schema evolution playbook](#schema-evolution-playbook) above. |
| [`CrossPlatformCodegenTests.swift`](../Tests/JsBaoClientTests/CrossPlatform/CrossPlatformCodegenTests.swift) | 4 | JS-Swift wire parity through the codegen path specifically. Skipped via `XCTSkip` if Node isn't available. Catches drift between codegen-emitted output and js-bao's encoding. |
| [`PluginScannerTests.swift`](../Tests/SwiftBaoCodegenTests/PluginScannerTests.swift) | 12 | Catches drift between `JsBaoCodegenPlugin.predictGeneratedFiles` and `TomlParser.parse`. The plugin's mini-TOML scanner has to predict the same model set the codegen tool emits — divergence surfaces as a "missing output" SwiftPM error at consumer build time. SwiftPM doesn't allow plugin code in test targets, so this file mirrors the plugin scanner with a load-bearing keep-in-sync comment. |
| [`SwiftEmitterTests.swift`](../Tests/SwiftBaoCodegenTests/SwiftEmitterTests.swift) | 17 | Emitter unit tests: header, custom module, public access, id-first pinning, required guards, type mappings, primitiveValues shape, descriptor flags, **comprehensive sweep of every reserved Swift keyword as a field name** with backtick escapes verified at all 6 emitter call sites, unicode field/model name handling. |
| [`TomlParserTests.swift`](../Tests/SwiftBaoCodegenTests/TomlParserTests.swift) | 12 | Parser unit tests: basic shape, class_name override, **class_name validation against identifier regex AND against reserved keywords**, field flags, defaults, compound unique, refersTo relationships, unknown field type, unknown rel target, bad unique fields, missing models table. |
| [`CrossPlatformTomlSchemaParityTests.swift`](../Tests/JsBaoClientTests/CrossPlatform/CrossPlatformTomlSchemaParityTests.swift) | (existing) | Parser parity between the runtime `TomlSchemaLoader` and js-bao's `loadSchemaFromTomlString` — guards the cross-language shape of the shared TOML grammar. |

### What's *not* covered here

A few things the gauntlet deliberately doesn't test, with where they
live instead:

- **Plugin invocation in a real consumer** — proven end-to-end by the
  demo (`primitive-app-demo`). The gauntlet tests use committed
  goldens, not the SPM build-tool plugin. If the plugin breaks (tool
  resolution, `prebuildCommand` rejection, etc.), the demo's `swift
  build` is what catches it.
- **Runtime relationship resolution** through codegen-emitted
  `RelationshipDescriptor`s. We pin the literal emission and that a
  relationship-bearing model's typed CRUD works, but we don't follow
  a `refersTo` and assert the join. The runtime side is covered by
  [`IncludeResolverTests`](../Tests/JsBaoClientTests/Schema/IncludeResolverTests.swift) and [`RelationshipsRuntimeTests`](../Tests/JsBaoClientTests/Schema/RelationshipsRuntimeTests.swift) using
  hand-built descriptors. Closing this gap is one targeted test away
  if you want it.
- **`type = "json"`** — the codegen rejects this at parse time
  today; gap-not-test.

### On-device companion (`primitive-app-demo`)

The demo carries a "Codegen Gauntlet" page that mirrors the XCTest
one-for-one (plus a `BaoDataLoader<[T]>` reactive smoke that XCTest
can't run because the loader is `@MainActor` SwiftUI). It's hidden
behind `PRIMITIVE_DEV_TOOLS=1` in `.env.local`. The XCTest is the
test of record; the on-device run proves the same codegen output
behaves correctly inside a real SwiftUI app target.

See [`primitive-app-demo/docs/README.md`](../../../primitive-app-demo/docs/README.md) → "The Codegen Gauntlet"
for setup and the full mirror table.
