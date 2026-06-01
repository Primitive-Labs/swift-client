# Schema and model layer parity

This is the highest-risk parity surface. The Swift `Sources/JsBaoClient/Schema/` directory reimplements parts of `js-bao` — *not* the JS client, but the underlying ORM-like layer at `packages/js-bao/`. Both sides must agree on schemas, field types, relationships, validation rules, and how records are written into Y.Doc maps.

## Concept map: js-bao ↔ Swift Schema/

| js-bao concept | Swift counterpart | Status |
|---|---|---|
| `BaseModel.ts` (CRUD + observers + queries) | `DynamicModel.swift` + `TypedModel.swift` | ⚠️ partial — see below |
| `schema.ts` (`PrimitiveSchema`, registry) | `PrimitiveSchema.swift`, `PrimitiveSchemaRegistry.swift` | ✅ |
| `tomlLoader.ts` | `TomlSchemaLoader.swift` | ⚠️ — see below |
| `relationshipManager.ts` | `RelationshipResolution.swift` + `IncludeResolver.swift` | ✅ |
| `metaSync.ts` (`_meta_*` synthesis) | `SchemaSync.swift` | ✅ — Swift cache is more careful (handles ObjectIdentifier re-issue) |
| `StringSet.ts` (set wrapper) | `PrimitiveValue.swift` (stringset case) | ⚠️ — see [wire-format.md](wire-format.md) |

## Field types

| TOML `type` | js-bao runtime | Swift `PrimitiveValue` | Status |
|---|---|---|---|
| `id` | `string`, ULID-generated | `String`, ULID-generated | ✅ |
| `string` | `string` | `String` | ✅ |
| `number` | `number` | `Double` | ✅ |
| `boolean` | `boolean` | `Bool` | ✅ |
| `date` | `string` (ISO format) | `String` (ISO format) | ✅ |
| `stringset` | `StringSet` (custom wrapper) | `Set<String>` | ⚠️ wire-format diverges (see wire-format.md) |

## Field-level options

| Option | js-bao | Swift | Status |
|---|---|---|---|
| `required` | ✅ | ✅ | ✅ |
| `auto_assign` | ✅ | ✅ | ✅ |
| `indexed` | ✅ | ✅ | ✅ |
| `unique` | ✅ | ✅ | ✅ |
| `default` | ✅ literal or function | ✅ literal | ⚠️ Swift function-default support gap |

## Relationships

| Type | js-bao | Swift | Status |
|---|---|---|---|
| `refersTo` | ✅ | ✅ | ✅ — uses `<related_id_field>` for target lookup |
| `hasMany` | ✅ | ✅ | ✅ — filter + order_by + order_direction |
| `hasManyThrough` | ✅ | ✅ | ✅ — join model walk |
| `refersToMany` (rare) | ✅ | ⛔ | not exposed |

### Relationship resolution details

| Concept | js-bao | Swift | Status |
|---|---|---|---|
| Eager `Include` (batch lookup) | ✅ uses query engine | ✅ uses query engine | ✅ |
| Lazy `record.posts()` (single) | ✅ batch via `dataloader` | ⚠️ `findAll().filter` (O(N), no pagination) | ⚠️ P2 perf concern |
| Pagination on hasMany | yes | only via batch path | ⚠️ P2 |
| Cursor pagination on hasMany | yes | yes (batch path) | ✅ |
| Order direction case-sensitivity | strict (`"ASC"` only) | lenient (`"DESC"` triggers desc, anything else is asc) | ⚠️ documented in schema.toml |

## TOML schema loader

| Concept | js-bao | Swift | Status |
|---|---|---|---|
| Strict-by-default (rejects unknown keys) | ✅ since the v2 codegen change | ✅ since [#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789) | ✅ — `strict: false` is the legacy escape hatch |
| `hasMany.related_id_field` required | ✅ | ✅ | ✅ ([#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)) |
| `hasManyThrough.join_model_local_field` required | ✅ | ✅ | ✅ ([#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)) |
| `hasManyThrough.join_model_related_field` required | ✅ | ✅ | ✅ ([#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)) |
| `class_name` override | ✅ | ✅ | ✅ — both codegens use this |
| Field-type validation | ✅ | ✅ | ✅ |
| Compound unique constraints | ✅ | ✅ | ✅ |

## Typed-model surface

The "typed CRUD/query API on top of a schema" — js-bao calls it `BaseModel`, Swift splits into `TypedModel<T>` (the wrapper) + `PrimitiveModel` (the protocol every codegen'd struct conforms to) + `DynamicModel` (the schemaless backing). See [`../baomodels.md`](../baomodels.md) for the full author-side guide.

| BaseModel feature (js-bao) | Swift surface | Status |
|---|---|---|
| `Model.find(id)` | `TypedModel<T>.find(id:)` | ✅ |
| `Model.findAll()` | `TypedModel<T>.findAll()` | ✅ |
| `Model.create(value)` | `TypedModel<T>.create(_:)` | ✅ |
| `Model.delete(id)` | `TypedModel<T>.delete(id:)` | ✅ |
| `Model.query(filter, options)` | `TypedModel<T>.query(_:options:)` | ⚠️ Swift returns `[T]` but loses `nextCursor` — drop down to `model.dynamic.queryPaged(...)` for pagination |
| `Model.queryOne(filter)` | — | ⛔ |
| `Model.findByUnique(constraint, value)` | — | ⛔ |
| `Model.update(id, partialFields)` | — | ⛔ — no `update` on `TypedModel<T>` |
| `inst.save()` (live wrapper writes to Y.Map) | — | ⛔ — Swift structs are values, no live write-through |
| `inst.delete()` (instance method) | — | ⛔ |
| `Model.subscribe(filter, listener)` | `DynamicModel.subscribe(...)` | ✅ via dynamic surface |
| `record.posts()` (relationship) | `record.posts()` (relationship) | ✅ |
| Migrate-to-nested-Y.Maps tooling | — | ⛔ (probably fine to skip) |

`TypedModel<T>` is **intentionally minimal** as of v1. Most CRUD richness lives on `DynamicModel`; `TypedModel<T>` is a thin sugar wrapper. v1.1 polish: lift `update`, `queryOne`, `findByUnique` into `TypedModel<T>` so callers don't have to drop to `model.dynamic` for common cases.

## DynamicModel — the workhorse

`DynamicModel.swift` is **1,431 lines** and bundles 7 concerns: CRUD, query, observers, listeners, reconciliation, internals, helpers. Functional but should split in followup. See `pr349-review/05-schema.md` for proposed splits.

Concurrent-write safety story:
- yrs `RwLock` at the bottom + observer-drain queue on top + thread-local active-tx
- ✅ Sound. Two minor concerns (logged in review):
  - `notifyListeners()` fires **synchronously inside the write tx** — a subscriber that calls `query()` could in theory race with the commit hook. Recommendation: defer notification to after commit.
  - `transact { ... }` doesn't roll back on throw (yrs limitation). Should be doc'd more loudly.

## MultiDocModel — Swift-only concept (exists in js-bao too, different name)

| Concept | js-bao | Swift |
|---|---|---|
| Indexing across multiple docs | `BaseModel.dbInstance` design | `MultiDocModel.swift` |

`MultiDocModel.swift` (452 lines) is the cross-doc indexing layer. The file's own header says it "Mirrors js-bao's BaseModel.dbInstance design." Functional and clean.

## Layering ✅

`Sources/Schema/` imports only Foundation, TOMLKit, YSwift, Yniffi. No reach-ins to `Internal/` or `API/`. Clean dependency graph.

## Known divergences in summary

| # | Issue | Severity | Status |
|---|---|---|---|
| 1 | TOML loader not strict-by-default | P1 | ✅ closed ([#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)) |
| 2 | TOML loader missing required-field validation for hasMany / hasManyThrough | P2 | ✅ closed ([#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)) |
| 3 | Stringset wire format (see wire-format.md) | P1 | ⚠️ open |
| 4 | Stringset full-replace semantics (CRDT-unfriendly under offline writes) | P2 architectural | ⚠️ open |
| 5 | `TypedModel<T>` minimal — no `update`, `queryOne`, `findByUnique`, `queryPaged` | ⛔ v1, P2 v1.1 | ⚠️ open |
| 6 | `record.hasMany()` lazy path is `findAll().filter`, no pagination | ⚠️ P2 perf | ⚠️ open |
| 7 | `notifyListeners()` fires inside write tx | ⚠️ P3 | ⚠️ open |
| 8 | DynamicModel's 1,431 lines bundle 7 concerns | P3 cleanup | ⚠️ open |

## Notes for maintainers

When extending the schema layer:
- Anything that touches **field encoding/decoding** must be checked against `packages/js-bao/src/models/`. The cross-platform parity tests catch *some* of this; this doc enumerates the rest.
- New TOML attributes must be added to **both** loaders simultaneously.
- New relationship types need a parity test in `Tests/JsBaoClientTests/CrossPlatform/`.
- Adding/changing a `_meta_*` shape must keep js-bao readable — Swift writes that JS can't decode is a P0 wire-format break.
