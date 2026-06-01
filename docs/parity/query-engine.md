# Query engine parity

Mongo-style filters, sort, limit, cursor pagination, projections. The Swift query engine lives in [`Sources/JsBaoClient/Query/`](../../Sources/JsBaoClient/Query/) and translates filters into SQL against an in-memory SQLite mirror of the Y.Doc records.

JS counterpart: [`packages/js-bao/src/query/`](../../../packages/js-bao/src/query/).

## Filter operators

| Operator | js-bao | Swift | Status | Notes |
|---|---|---|---|---|
| `$eq` | ✅ | ✅ | ✅ | exact match |
| `$ne` | ✅ | ✅ | ✅ | NULL-row divergence closed in [#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789) — Swift now emits `col != ?`. |
| `$gt` | ✅ | ✅ | ✅ | |
| `$gte` | ✅ | ✅ | ✅ | |
| `$lt` | ✅ | ✅ | ✅ | |
| `$lte` | ✅ | ✅ | ✅ | |
| `$in` | ✅ | ✅ | ✅ | |
| `$nin` | ✅ | ✅ | ✅ | NULL-row divergence closed in [#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789). |
| `$exists` | ✅ | ✅ | ✅ | |
| `$contains` (stringset) | ✅ | ✅ | ✅ | |
| `$startsWith` | ✅ throws on non-string | 🔀 emits `0` on non-string field/value (no throw) | 🔀 | Engine tracks scalar string fields per model (`stringFieldsByModel`) and the translator emits `0` (matches nothing) when the field isn't string/stringset or the value isn't a string. js-bao throws; Swift's `dynamic.query` surface is non-throwing, so behavior is "no match" rather than "error". Result sets agree. ([#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)) |
| `$endsWith` | ✅ throws on non-string | 🔀 emits `0` on non-string field/value (no throw) | 🔀 | same as `$startsWith`. |
| `$containsText` | ✅ throws on non-string, trims, caps at 1024 | 🔀 emits `0` on non-string; trims; caps at 1024 (silent cap, not throw) | 🔀 | Same gating + js-bao's trim and 1024-char cap now applied via `prepareSubstringQuery`. Strict-throws on oversize is a v1.1 follow-up tied to making `dynamic.query` throws-aware. |
| `$and` | ✅ | ✅ | ✅ | |
| `$or` | ✅ | ✅ | ✅ | |
| `$not` | ✅ | ✅ | ✅ | |

**Follow-up**: the three 🔀 rows have *agreeing result sets* with js-bao but differ in *error semantics* (Swift: no throw, no match; js-bao: throws). Lifting the substring ops to throwing requires making `dynamic.query` / `aggregate` / `count` throws-aware. Tracked as a v1.1 polish.

Regression coverage: `Tests/JsBaoClientTests/Schema/WireFormatGapFixesTests.swift` pins each operator's behavior.

## Sort

| Concept | js-bao | Swift | Status |
|---|---|---|---|
| Default sort | `id ASC` | `id ASC` | ✅ |
| Implicit `id` tiebreaker | appended unless caller specifies | appended unless caller specifies | ✅ |
| Multi-field stable sort | yes | yes | ✅ |
| Direction | `1` / `-1` (or `"asc"`/`"desc"`) | `.ascending` / `.descending` | ✅ (semantic match, type-different) |

## Cursor pagination

| Concept | js-bao | Swift | Status |
|---|---|---|---|
| Cursor format | `{values, sortFields, direction}` JSON, base64-encoded | identical | ✅ — byte-compatible across languages |
| Direction | encoded in cursor | encoded in cursor | ✅ |
| Page size | `limit` option | `limit` option | ✅ |
| Concurrent-write robustness | uses unique key state | uses unique key state | ✅ |
| Malformed-cursor handling | throws | three different behaviors across `query()` / `queryPaged()` / inconsistent | ⚠️ |

**The cursor is interchangeable.** A cursor produced by Swift decodes correctly on JS and vice versa. Verified by `testCursorPaginationAgreesAcrossLanguages` in `Tests/JsBaoClientTests/CrossPlatform/E2EQueryParityTests.swift`.

## Projection

| Concept | js-bao | Swift | Status |
|---|---|---|---|
| Include only specific fields | yes | yes | ✅ |
| Mixed projection (some fields included, some excluded) | throws | `precondition` crashes | ⚠️ — Swift should `throw` instead of crashing |

## Aggregations

`aggregate()` (count / sum / min / max / avg) is implemented on both sides.

| Concept | js-bao | Swift | Status |
|---|---|---|---|
| `count` | ✅ | ✅ | ✅ |
| `sum` | ✅ | ✅ | ✅ |
| `min` / `max` | ✅ | ✅ | ✅ |
| `avg` | ✅ | ✅ | ✅ |
| Doc-scoped aggregation | injected via parameter | **string surgery on already-built SQL** (`sql.range(of: " WHERE ")`) | ⚠️ P2 code-smell, not a correctness bug |

**Recommended cleanup:** plumb `scopedToDocId` into `buildAggregation` instead of the post-build SQL surgery.

## Architecture notes

### Index update strategy: incremental, not full-rebuild

A common misread is that `BaoModelQueryEngine` does a "dirty-flag full rebuild on each query." That's not the steady state. The actual flow:

- **Local writes:** `DynamicModel.create / update / delete` mutates the SQLite mirror inline inside the same write path that mutates the Y.Map. No rebuild.
- **Remote writes (from a peer or sync):** flow through `DynamicModel`'s **per-record observer + root-map observer** pipeline (see file header on `DynamicModel.swift`: "Mirrors js-bao's `BaseModel`" + "per-record observers"). The observers translate Y.Map deltas into incremental SQLite updates via `observerDrainQueue`.
- **Full rebuild:** exists as a *fallback* (e.g., the engine being attached fresh to a doc that already has records, or when the dirty flag is set after a path that doesn't deliver per-record events). It's not what runs on every query.

So the "incremental updates" parity question with js-bao is closed at the layer that matters (`DynamicModel`); the engine itself just supports both paths.

### File size

[`BaoModelQueryEngine.swift`](../../Sources/JsBaoClient/Query/BaoModelQueryEngine.swift) is 1,041 lines. **Not a god class** — concerns are tightly coupled by lock discipline. Modest cleanup splits available:
- Extract `StringsetJunctions` helper (~200 lines)
- Extract `SQLiteHandle` primitive (~80 lines)

Neither blocks v1.

## Known divergences in summary

After [#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789):

1. ~~**`$ne` / `$nin` NULL handling differs**~~ — closed. Same query gives same result sets across both clients.
2. ~~**Substring operators silently match-all on non-strings in Swift**~~ — closed (Swift now emits `0`/no-match). Error semantics still differ (Swift: no throw; js-bao: throws); result sets agree.
3. **Cursor format is byte-compatible across languages** — bright spot.
4. **Mixed projection** — Swift `precondition` traps the process; js-bao throws. Still open ([wire-format.md](wire-format.md)).
5. **Malformed cursor handling** — three different behaviors across Swift entry points (`query` / `queryPaged` / inconsistent). Still open.

## Notes for maintainers

When extending the query engine:
- Add the new operator to **both** `QueryTranslator.swift` and `packages/js-bao/src/query/`.
- Decide error semantics together (throw? sentinel? match-all?). Document the choice.
- Add a cross-platform parity test in `Tests/JsBaoClientTests/CrossPlatform/E2EQueryParityTests.swift`.
- Update the operator table above.
