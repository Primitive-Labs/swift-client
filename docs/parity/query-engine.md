# Query engine parity

Mongo-style filters, sort, limit, cursor pagination, projections. The Swift query engine lives in [`Sources/JsBaoClient/Query/`](../../Sources/JsBaoClient/Query/) and translates filters into SQL against an in-memory SQLite mirror of the Y.Doc records.

JS counterpart: [`packages/js-bao/src/query/`](../../../packages/js-bao/src/query/).

## Filter operators

| Operator | js-bao | Swift | Status | Notes |
|---|---|---|---|---|
| `$eq` | ✅ | ✅ | ✅ | exact match |
| `$ne` | ✅ | ⚠️ | ⚠️ | **Swift includes NULL rows** (`(col != ? OR col IS NULL)`); js-bao excludes them. Different result sets. |
| `$gt` | ✅ | ✅ | ✅ | |
| `$gte` | ✅ | ✅ | ✅ | |
| `$lt` | ✅ | ✅ | ✅ | |
| `$lte` | ✅ | ✅ | ✅ | |
| `$in` | ✅ | ✅ | ✅ | |
| `$nin` | ✅ | ⚠️ | ⚠️ | same NULL-handling divergence as `$ne` |
| `$exists` | ✅ | ✅ | ✅ | |
| `$contains` (stringset) | ✅ | ✅ | ✅ | |
| `$startsWith` | ✅ throws on non-string | ⚠️ silently `1=1` | ⚠️ | non-string fallback differs |
| `$endsWith` | ✅ throws on non-string | ⚠️ silently `1=1` | ⚠️ | same |
| `$containsText` | ✅ throws on non-string, trims, caps at 1024 | ⚠️ silently `1=1`, no trim, no cap | ⚠️ | same |
| `$and` | ✅ | ✅ | ✅ | |
| `$or` | ✅ | ✅ | ✅ | |
| `$not` | ✅ | ✅ | ✅ | |

**Action:** the four ⚠️ rows are localized fixes in [`QueryTranslator.swift`](../../Sources/JsBaoClient/Query/QueryTranslator.swift). See [wire-format.md](wire-format.md) for why these are wire-format issues and not just translator bugs.

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

If you only remember three things from this doc:

1. **`$ne` / `$nin` NULL handling differs** — same query gives different results.
2. **Substring operators silently match-all on non-strings in Swift** — js-bao throws.
3. **Cursor format is byte-compatible across languages** — that one's a bright spot.

Everything else is parity.

## Notes for maintainers

When extending the query engine:
- Add the new operator to **both** `QueryTranslator.swift` and `packages/js-bao/src/query/`.
- Decide error semantics together (throw? sentinel? match-all?). Document the choice.
- Add a cross-platform parity test in `Tests/JsBaoClientTests/CrossPlatform/E2EQueryParityTests.swift`.
- Update the operator table above.
