# Wire-format parity

The most important parity surface — and the one that bites silently when it diverges. If Swift and JS write the same logical record into a Y.Doc differently, then a record written by one client and read by the other won't query equivalently. The 9-agent review of PR #349 surfaced these:

## What's verified parity ✅

These are byte-equivalent across the language boundary, confirmed by either the cross-platform parity tests in `Tests/JsBaoClientTests/CrossPlatform/` or by direct code inspection.

| Layer | Verified shape |
|---|---|
| Y.Doc CRDT updates | Same wire bytes — both clients delegate to `yrs::Update::decode_v1` / `encode_v1` (Swift via the YSwift fork's FFI; JS via `yjs` npm). |
| `OffsetKind::Utf16` | Both use UTF-16 offsets (browser-compatible). Swift hardcodes this; JS uses it natively via `yjs`. |
| Cursor pagination format | Same `{values, sortFields, direction}` JSON shape, same base64 transport. A cursor produced by either side decodes on the other. (Verified in `testCursorPaginationAgreesAcrossLanguages`.) |
| Sort + tiebreaker | Default `id ASC`, implicit `id` appended unless caller supplies it; lexicographic multi-field WHERE for cursor pagination. (Verified against js-bao `CursorManager`.) |
| Error code strings | All 19 `JsBaoErrorCode` cases match exactly. See [errors.md](errors.md). |
| `_meta_*` synthesis | The schema metadata js-bao writes alongside records (`_meta_<modelname>` map entries) is emitted by Swift in the same shape. Swift's `NSMapTable`-with-weak-keys cache is even more careful than js-bao's `WeakMap` (handles `ObjectIdentifier` re-issue). |
| Single-record CRUD round-trip | Swift writes → JS reads → Swift reads (and vice-versa) for scalar fields: string, number, boolean, date. |

## What diverges ⚠️ — fix before declaring v1 wire-stable

### 1. Stringset member values (P1)

| | js-bao | Swift |
|---|---|---|
| Wire shape | nested Y.Map keyed by member, value `true` | nested Y.Map keyed by member, value JSON-encoded member name |
| Read tolerance | reads either shape | reads either shape |
| Write parity | Same data, different bytes |

**Source:** `Sources/JsBaoClient/Schema/DynamicModel.swift:1218`. One-line fix: change the value-side encoding to boolean `true` to match js-bao.

**Why this matters:** even though both clients can *read* either shape, byte-equality assertions in cross-platform tests fail, and any downstream tooling that does raw Y.Doc inspection sees different content for "the same" record.

### 2. `$ne` and `$nin` NULL handling (P1)

| | js-bao | Swift |
|---|---|---|
| `field $ne X` | `col != ?` (excludes NULL rows) | `(col != ? OR col IS NULL)` (includes NULL rows) |
| `field $nin [...]` | excludes NULLs | includes NULLs |

**Source:** `Sources/JsBaoClient/Query/QueryTranslator.swift`. Same query, same data, **different result sets across languages.**

This is the most insidious wire-format gap because it doesn't affect storage — only query results. A "the test passed on JS but failed on Swift" debugging session is exactly this kind of bug.

### 3. Substring operators on non-strings (P1)

`$startsWith`, `$endsWith`, `$containsText` against a non-string value:

| | js-bao | Swift |
|---|---|---|
| Behavior | throws | silently falls back to `"1=1"` (matches all rows) |
| Trim | yes | no |
| Cap | 1024 chars | uncapped |

**Source:** same translator file. js-bao's "throw on bad input" is the better contract; Swift should match.

### 4. TOML loader strict mode (P1)

| | js-bao | Swift |
|---|---|---|
| Default | strict (rejects unknown keys) | permissive (silently accepts everything) |
| Result | typo'd schema fails loud | typo'd schema passes Swift, fails JS later |

**Source:** `Sources/JsBaoClient/Schema/TomlSchemaLoader.swift`. Flip the default.

### 5. TOML loader required-field divergences (P2)

| Field | js-bao | Swift |
|---|---|---|
| `hasMany.related_id_field` | required | optional |
| `hasManyThrough.join_model_local_field` | required | optional |
| `hasManyThrough.join_model_related_field` | required | optional |

### 6. Stringset write semantics (P2 — architectural)

| | js-bao | Swift |
|---|---|---|
| Add member | nested Y.Map `set(member, true)` | overwrite entire nested Y.Map |
| Concurrent writes | union (CRDT-merge) | last-writer-wins (overwrite race) |

**Architectural fix needed:** Swift `DynamicModel` needs `addMember(_:)` / `removeMember(_:)` APIs that do per-member writes instead of full-replace. Without this, two offline Swift clients adding members to the same set will lose each other's adds when they reconnect.

### 7. Number encoding for large magnitudes (P3)

| | js-bao | Swift |
|---|---|---|
| `Number.toString()` for `1e20` | `"100000000000000000000"` (full digits via `JSON.stringify`) | `"1e+20"` (scientific notation via `String(Double)`) |

Both parse to the same `lib0::Any::Number` value. Byte snapshots differ. Affects nothing semantically but breaks byte-equality tests.

### 8. Single-doc `_meta_doc_id` (P3, SQLite-only)

| | js-bao | Swift |
|---|---|---|
| Default value | `"__legacy_default__"` | `""` (empty string) |

Doesn't affect Y.Doc CRDT — only the SQLite mirror's `_meta_doc_id` column. SQLite-only, internal, but worth aligning.

### 9. `StorageRecord` field divergence (P1)

| Field | js-bao | Swift |
|---|---|---|
| `updatedAtMs` | present (used for `refreshIfOlderThanMs` cache freshness) | dropped |
| `metadata` type | `Record<string, unknown> \| null` | `[String: String]?` (Swift) |

Swift's `metadata` type is too narrow. If JS writes a `StorageRecord` with non-string metadata values, Swift can't round-trip them.

### 10. Event names — see [events.md](events.md)

16 places where event-name parity diverges. Not a Y.Doc wire-format issue per se, but it's the same class of contract mismatch — both clients have to agree on the strings.

## Summary table

| # | Issue | Severity | Where |
|---|---|---|---|
| 1 | Stringset member value (boolean vs JSON-encoded string) | P1 | DynamicModel.swift:1218 |
| 2 | `$ne` / `$nin` NULL handling | P1 | QueryTranslator.swift |
| 3 | Substring operators on non-strings | P1 | QueryTranslator.swift |
| 4 | TOML loader strict mode | P1 | TomlSchemaLoader.swift |
| 5 | TOML loader required-field validation | P2 | TomlSchemaLoader.swift |
| 6 | Stringset write semantics (full-replace) | P2 (arch) | DynamicModel.swift |
| 7 | Number encoding for large magnitudes | P3 | DynamicModel.swift / PrimitiveValue |
| 8 | `_meta_doc_id` default | P3 | SQLite |
| 9 | `StorageRecord` field divergence | P1 | OfflineStore.swift |
| 10 | Event names | P1 | Events.swift (see events.md) |

Most are localized fixes — the biggest single PR to land would be a "wire-format alignment pass" that closes these 10 in a few hours.

## Notes for maintainers

When you add or change anything in:
- `Sources/JsBaoClient/Schema/DynamicModel.swift` (especially how fields are written)
- `Sources/JsBaoClient/Schema/PrimitiveValue.swift` (encoding/decoding)
- `Sources/JsBaoClient/Schema/TomlSchemaLoader.swift` (validation)
- `Sources/JsBaoClient/Query/QueryTranslator.swift` (operator translation)

…ask "does the JS side write the same bytes here?" If yes, write a cross-platform parity test. If no, flag it in this doc.
